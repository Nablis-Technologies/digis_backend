# frozen_string_literal: true

module Events
  module Cancellation
    # Initiates the irreversible cancellation of an event. Under an event lock it
    # rejects a second cancellation, flips the event to cancelled (retaining
    # published_at for history), records the single cancellation row, and writes
    # durable audit + outbox evidence. It deliberately performs NO refund or
    # payment-provider work: money movement is handled by a separate downstream
    # consumer of the events.cancellation_initiated outbox event.
    class Initiate < Core::BaseService
      def initialize(event:, actor:, idempotency_key:, internal_note: nil, attendee_reason: nil)
        @event = event
        @actor = actor
        @idempotency_key = idempotency_key
        @internal_note = internal_note
        @attendee_reason = attendee_reason
      end

      def call
        Events::Event.transaction do
          event.lock!

          existing = Events::EventCancellation.find_by(event_id: event.id)
          if existing
            # Same key = replay (idempotent); a different key = a real second
            # attempt at an irreversible action, which is rejected.
            return success(existing) if existing.idempotency_key == idempotency_key

            return already_cancelled_failure
          end

          previous_status = event.status
          event.update!(status: "cancelled", cancelled_at: Time.current)
          stop_streams(event)
          revoke_pending_staff_invitations!
          @cancellation = create_cancellation

          record_audit(previous_status)
          publish_outbox
        end

        Events::SyncStreamScheduleJob.perform_later(event.id)
        success(@cancellation)
      rescue ActiveRecord::RecordNotUnique
        already_cancelled_failure
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :event, :actor, :idempotency_key, :internal_note, :attendee_reason

      def create_cancellation
        Events::EventCancellation.create!(
          event: event,
          initiated_by: actor,
          internal_note: internal_note,
          attendee_reason: attendee_reason,
          status: "pending",
          idempotency_key: idempotency_key,
          total_payments_count: eligible_payment_count,
          initiated_at: Time.current
        )
      end

      def eligible_payment_count
        Orders::Payment.joins(:order)
          .where(orders_orders: { event_id: event.id }, status: "succeeded")
          .where.not(accepted_at: nil)
          .count
      end

      def stop_streams(event)
        Events::EventStream
          .joins(:event_date)
          .where(events_event_dates: { event_id: event.id })
          .where.not(status: "ended")
          .update_all(status: "ended", updated_at: Time.current)
      end

      def revoke_pending_staff_invitations!
        result = Events::StaffInvitations::RevokeForCancellation.call(event:, actor:)
        raise result.error if result.failure?
      end

      def record_audit(previous_status)
        event.record_audit!(
          "event.cancellation.initiated",
          audit_key: "event-cancellation-initiated-#{event.id}",
          audited_changes: { status: [ previous_status, "cancelled" ] },
          metadata: { idempotency_key: idempotency_key },
          actor: actor
        )
      end

      def publish_outbox
        Core::Outbox::Publish.call(
          topic: "events",
          event_type: "events.cancellation_initiated",
          aggregate: event,
          payload: { event_id: event.id },
          idempotency_key: "event-cancellation-initiated-#{event.id}"
        )
      end

      def already_cancelled_failure
        failure Core::BusinessError.new(
          I18n.t("events.cancellation.errors.already_cancelled"),
          code: "already_cancelled",
          status: :unprocessable_entity
        )
      end
    end
  end
end
