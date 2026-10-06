# frozen_string_literal: true

require "set"

module Events
  module Cancellation
    # Claims and resolves one durable cancellation-payment snapshot. Refund
    # creation is deterministic per payment/item; a resale chain may create
    # obligations for several snapshots, but provider I/O remains scoped to
    # the claimed payment. A pending-funds retry reuses the original refund
    # row instead of creating a second financial obligation.
    class ProcessPayment < Core::BaseService
      RETRY_DELAY = 15.minutes

      def initialize(cancellation:, now: Time.current)
        @cancellation = cancellation
        @now = now.to_time.utc
      end

      def call
        snapshot = claim_snapshot
        return success(nil) unless snapshot

        refunds = create_refunds(snapshot)
        # A chain command may materialize obligations for several payment
        # snapshots. Each worker owns provider submission for its claimed
        # payment only; the other snapshots will submit their own obligations
        # on their next retry, keeping provider and finance work bounded.
        refunds = refunds.select { |refund| refund.payment_id == snapshot.payment_id }
        submit_refunds(refunds)
        update_snapshot(snapshot, refunds)
      rescue ActiveRecord::RecordNotFound
        failure(cancellation_error(:cancellation_failed, :not_found))
      rescue ActiveRecord::RecordInvalid => error
        update_failed_snapshot(snapshot, error.record.errors.full_messages.join(", ")) if snapshot
        success(snapshot)
      rescue Core::Error => error
        update_failed_snapshot(snapshot, error.code || "cancellation_failed") if snapshot
        success(snapshot)
      end

      private

      def claim_snapshot
        Events::EventCancellationPayment.transaction do
          candidates = Events::EventCancellationPayment
            .where(event_cancellation_id: @cancellation.id)
            .where(
              "(status = 'pending' AND (next_retry_at IS NULL OR next_retry_at <= ?)) OR " \
                "(status = 'processing' AND next_retry_at IS NOT NULL AND next_retry_at <= ?) OR " \
                "(status IN (?) AND payment_id IN (?))",
              @now, @now,
              %w[pending failed processing],
              Orders::Refund.where(
                event_cancellation_id: @cancellation.id,
                status: %w[pending_funds processing]
              ).where("next_retry_at IS NULL OR next_retry_at <= ?", @now).select(:payment_id),
            )
            .order(:id)
            .lock("FOR UPDATE SKIP LOCKED")
          snapshot = candidates.first
          next unless snapshot

          snapshot.update!(
            status: "processing",
            attempts: snapshot.attempts + 1,
            last_error: nil,
            next_retry_at: @now + RETRY_DELAY
          )
          snapshot
        end
      end

      def create_refunds(snapshot)
        payment = Orders::Payment.includes(order: { order_items: :event_product }).lock.find(snapshot.payment_id)
        chain_tickets = acquisition_chain_tickets(payment)
        chain_refunds = chain_tickets.flat_map do |ticket|
          result = Marketplace::CancelAcquisitionChainValue.call(
            ticket:,
            idempotency_key: "event-cancellation-acquisition-chain-#{@cancellation.id}-#{ticket.id}",
            event_cancellation: @cancellation,
            at: @now
          )
          raise result.error if result.failure?

          result.value
        end
        ticket_ids = payment.order.order_items.filter_map { |item| item.id if item.type_snapshot == "ticket" }
        tickets_by_item = Ticketing::Ticket.where(
          order_item_id: ticket_ids,
          status: "active",
          current_acquisition_type: Ticketing::Ticket::PAID_ACQUISITION_TYPES
        ).order(:id).group_by(&:order_item_id)
        refunds = []
        refundable_items(payment.order, tickets_by_item:, excluded_ticket_ids: chain_tickets.map(&:id)).each do |item, ticket|
          key = "event-cancellation-refund-#{@cancellation.id}-#{item.id}-#{ticket&.id || 'item'}"
          result = Orders::CreateItemRefund.call(
            payment:,
            order_item: item,
            ticket:,
            quantity: ticket ? 1 : item.quantity,
            reason_code: "event_cancellation",
            idempotency_key: key,
            event_cancellation: @cancellation
          )
          raise result.error if result.failure?
          refunds << result.value
        end
        chain_refunds + refunds
      end

      def acquisition_chain_tickets(payment)
        original_ticket_ids = Ticketing::Ticket.where(
          order_item_id: payment.order.order_items.select(:id)
        ).select(:id)
        sale_scope = Marketplace::ResaleSale.where(event_id: @cancellation.event_id)
          .where(accepted_payment_id: payment.id)
          .or(
            Marketplace::ResaleSale.where(event_id: @cancellation.event_id)
              .where(ticket_id: original_ticket_ids)
          )
        sale_ticket_ids = sale_scope.select(:ticket_id)

        Ticketing::Ticket.where(id: sale_ticket_ids).order(:id).to_a
      end

      def refundable_items(order, tickets_by_item:, excluded_ticket_ids: [])
        gift_order_item_ids = Orders::GiftPurchase.where(
          order_item_id: order.order_items.select(:id)
        ).pluck(:order_item_id).to_set
        order.order_items.flat_map do |item|
          if item.type_snapshot == "ticket"
            tickets = tickets_by_item.fetch(item.id, [])
            next [ [ item, nil ] ] if tickets.empty? && gift_order_item_ids.include?(item.id)

            tickets.filter_map do |ticket|
              next if excluded_ticket_ids.include?(ticket.id)

              [ item, ticket ]
            end
          elsif !item.fulfilled?
            [ [ item, nil ] ]
          else
            []
          end
        end
      end

      def submit_refunds(refunds)
        refunds.each do |refund|
          next if refund.status == "succeeded"
          if refund.status == "processing"
            result = Orders::ReconcileRefund.call(refund:, now: @now)
          else
            result = Orders::SubmitRefund.call(refund:, now: @now)
          end
          raise result.error if result.failure?
        end
      end

      def update_snapshot(snapshot, refunds)
        statuses = refunds.map { |refund| refund.reload.status }
        if statuses.empty? || statuses.all? { |status| status == "succeeded" }
          finalize_snapshot(snapshot, status: "resolved", error: nil, next_retry_at: nil)
        elsif statuses.any? { |status| status == "failed" }
          finalize_snapshot(snapshot, status: "failed", error: "refund_failed", next_retry_at: nil)
        elsif statuses.any? { |status| status == "processing" }
          retry_at = refunds.filter_map(&:reload).filter_map(&:next_retry_at).min
          finalize_snapshot(
            snapshot,
            status: "processing",
            error: "refund_processing",
            next_retry_at: retry_at || (@now + RETRY_DELAY)
          )
        else
          retry_at = refunds.filter_map(&:reload).filter_map(&:next_retry_at).min
          finalize_snapshot(
            snapshot,
            status: "pending",
            error: "pending_funds",
            next_retry_at: retry_at || (@now + RETRY_DELAY)
          )
        end
      end

      def update_failed_snapshot(snapshot, error_code)
        finalize_snapshot(
          snapshot,
          status: "pending",
          error: error_code.to_s,
          next_retry_at: @now + RETRY_DELAY
        )
      end

      def finalize_snapshot(snapshot, status:, error:, next_retry_at:)
        Events::EventCancellation.transaction do
          locked_snapshot = Events::EventCancellationPayment.lock.find(snapshot.id)
          cancellation = Events::EventCancellation.lock.find(locked_snapshot.event_cancellation_id)
          locked_snapshot.update!(
            status:,
            last_error: error,
            next_retry_at:,
            resolved_at: status == "resolved" ? (@now) : nil
          )
          resolved = cancellation.payment_snapshots.where(status: "resolved").count
          failed = cancellation.payment_snapshots.where(status: "failed").count
          failed += cancellation.payment_snapshots.where(status: "pending")
            .where.not(last_error: nil).count
          final_status = if resolved == cancellation.total_payments_count
            "completed"
          elsif failed.positive?
            "partially_failed"
          else
            "processing"
          end
          cancellation.update!(
            status: final_status,
            resolved_payments_count: resolved,
            failed_payments_count: failed,
            completed_at: final_status == "completed" ? (cancellation.completed_at || @now) : nil
          )
          success(locked_snapshot)
        end
      end

      def cancellation_error(key, status = :unprocessable_entity, errors: nil)
        Core::BusinessError.new(
          I18n.t("events.cancellation.errors.#{key}"), code: key, status:, errors:
        )
      end
    end
  end
end
