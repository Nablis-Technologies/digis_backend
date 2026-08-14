# frozen_string_literal: true

module Events
  module Cancellation
    # Materializes the bounded work for one irreversible event cancellation.
    # The cancellation row and event are locked together so date shutdown,
    # free-credential revocation, and payment snapshots cannot observe a
    # partially prepared cancellation. Replays only reconcile existing rows.
    class PrepareBatch < Core::BaseService
      BATCH_SIZE = 50

      def initialize(cancellation:)
        @cancellation = cancellation
      end

      def call
        enqueue = false
        Events::Event.transaction do
          cancellation = Events::EventCancellation.lock.find(@cancellation.id)
          event = Events::Event.lock.find(cancellation.event_id)

          unless cancellation.status == "completed"
            snapshot_payments!(cancellation, event)
            cancel_future_dates!(cancellation, event)
            stop_event_workflows!(event)
            revoke_free_tickets!(event)
            update_progress!(cancellation)
            enqueue = cancellation.status != "completed"
          end
          @prepared_cancellation = cancellation
        end

        Events::ProcessCancellationBatchJob.perform_later(@prepared_cancellation.id) if enqueue
        success(@prepared_cancellation)
      rescue ActiveRecord::RecordNotFound
        failure(cancellation_error(:cancellation_failed, :not_found))
      rescue ActiveRecord::RecordInvalid => error
        failure(cancellation_error(:cancellation_failed, errors: error.record.errors.to_hash))
      rescue Core::Error => error
        failure(error)
      end

      private

      def snapshot_payments!(cancellation, event)
        return if cancellation.refunds_started_at.present?

        payment_ids = Orders::Payment.joins(:order)
          .where(orders_orders: { event_id: event.id }, status: "succeeded")
          .where.not(accepted_at: nil)
          .order(:id)
          .pluck(:id)
        now = Time.current
        rows = payment_ids.map do |payment_id|
          {
            id: SecureRandom.uuid,
            event_cancellation_id: cancellation.id,
            payment_id:,
            status: "pending",
            attempts: 0,
            lock_version: 0,
            created_at: now,
            updated_at: now
          }
        end
        Events::EventCancellationPayment.insert_all(
          rows,
          unique_by: :idx_event_cancellation_payments_unique
        ) unless rows.empty?
        cancellation.update!(total_payments_count: payment_ids.length)
      end

      def cancel_future_dates!(cancellation, event)
        dates = event.event_dates.where("ends_at > ?", Time.current)
          .where(status: %w[scheduled postponed])
          .order(:id).lock.to_a
        return if dates.empty?

        now = Time.current
        dates.each do |date|
          Events::EventDateChange.create!(
            event:,
            event_date: date,
            event_cancellation: cancellation,
            change_type: "cancelled",
            old_start_at: date.starts_at,
            old_end_at: date.ends_at,
            scheduled_by: cancellation.initiated_by
          )
          date.update_columns(status: "cancelled", updated_at: now)
        end
        event.update!(schedule_version: event.schedule_version + 1)
      end

      def stop_event_workflows!(event)
        date_ids = event.event_dates.select(:id)
        Events::EventStream.where(event_date_id: date_ids, status: %w[scheduled live])
          .update_all(status: "ended", updated_at: Time.current)

        active_registrations = Ticketing::Registration.active.where(event_id: event.id).lock.to_a
        active_registrations.each do |registration|
          registration.update!(status: "cancelled", cancelled_at: Time.current)
          release_registration_capacity!(registration)
        end
        Ticketing::Invitation.joins(ticket_type: :event_product)
          .where(catalog_event_products: { event_id: event.id }, status: %w[pending accepted])
          .update_all(status: "revoked", updated_at: Time.current)

        reservation_group_ids = Catalog::InventoryReservation.joins(product_inventory: :event_product)
          .where(catalog_event_products: { event_id: event.id }, status: %w[held processing])
          .distinct.pluck(:reservation_group_id)
        reservation_group_ids |= Catalog::VenueCapacityReservation
          .where(event_product_id: event.event_products.select(:id), status: %w[held processing])
          .distinct.pluck(:reservation_group_id)
        reservation_group_ids.sort.each do |reservation_group_id|
          result = Catalog::Inventory::Release.call(reservation_group_id:)
          raise result.error if result.failure?
        end
      end

      def release_registration_capacity!(registration)
        group_ids = Catalog::InventoryReservation.where(
          registration_id: registration.id, status: %w[held processing]
        ).distinct.pluck(:reservation_group_id)
        group_ids.concat(
          Catalog::VenueCapacityReservation.where(
            registration_id: registration.id, status: %w[held processing]
          ).distinct.pluck(:reservation_group_id)
        )
        group_ids.uniq.sort.each do |reservation_group_id|
          result = Catalog::Inventory::Release.call(reservation_group_id:)
          raise result.error if result.failure?
        end

        return unless Ticketing::PurchaseLimitAllocation.where(
          registration_id: registration.id, status: %w[reserved committed]
        ).exists?

        result = Ticketing::PurchaseLimits::Release.call(
          registration:,
          user: registration.user,
          reason: "cancelled",
          idempotency_key: "events-cancellation-registration-#{registration.id}"
        )
        raise result.error if result.failure?
      end

      def revoke_free_tickets!(event)
        Ticketing::Ticket.where(
          event_id: event.id,
          status: "active",
          current_acquisition_type: Ticketing::Ticket::FREE_ACQUISITION_TYPES
        ).order(:id).find_each(batch_size: BATCH_SIZE) do |ticket|
          result = RevokeFreeTicket.call(ticket:)
          raise result.error if result.failure?
        end
      end

      def update_progress!(cancellation)
        resolved = cancellation.payment_snapshots.where(status: "resolved").count
        failed = cancellation.payment_snapshots.where(status: "failed").count
        status = if resolved == cancellation.total_payments_count
          "completed"
        elsif failed.positive?
          "partially_failed"
        else
          "processing"
        end
        cancellation.update!(
          status:,
          resolved_payments_count: resolved,
          failed_payments_count: failed,
          completed_at: status == "completed" ? (cancellation.completed_at || Time.current) : nil,
          refunds_started_at: cancellation.refunds_started_at || Time.current
        )
      end

      def cancellation_error(key, status = :unprocessable_entity, errors: nil)
        Core::BusinessError.new(
          I18n.t("events.cancellation.errors.#{key}"), code: key, status:, errors:
        )
      end
    end
  end
end
