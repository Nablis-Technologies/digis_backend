# frozen_string_literal: true

module Ticketing
  module Registrations
    # Confirms registrations for a zero-total order after Orders has reserved
    # capacity; ticket creation remains owned by the order fulfillment outbox.
    class ConfirmFreeOrder < Core::BaseService
      include Support

      def initialize(registration:, order_id:, actor:, idempotency_key:, at: Time.current)
        @registration_id = registration.id
        @order_id = order_id
        @actor = actor
        @idempotency_key = idempotency_key
        @at = at.to_time.utc
      end

      def call
        key_digest = Core::IdempotencyKey.new(@idempotency_key).digest
        outcome = Registration.transaction do
          event_id = Registration.where(id: @registration_id).pick(:event_id)
          event = Events::Event.lock.find(event_id)
          registration = Registration.lock.includes(:consent_requirements).find(@registration_id)
          next success(registration) if registration.confirmed?
          next failure(workflow_error("event_cancelled")) if event.status == "cancelled"
          next failure(workflow_error("registration_not_confirmable")) unless
            registration.status.in?(%w[pending_payment offered])
          next failure(workflow_error("required_buyer_consent_missing")) unless
            required_buyer_consents_complete?(registration)

          status_before = registration.status
          registration.update!(
            status: "confirmed",
            approved_at: registration.approved_at || @at,
            confirmed_at: @at,
            waitlisted_at: nil,
            offered_at: nil,
            offer_expires_at: nil,
            next_action_snapshot: nil
          )
          record_confirmation!(registration, key_digest, status_before:)
          success(registration)
        end

        outcome
      rescue ArgumentError
        failure(workflow_error("invalid_idempotency_key"))
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.registration_workflows.errors.invalid_registration"),
            code: "invalid_registration",
            status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      end

      private

      def record_confirmation!(registration, key_digest, status_before:)
        result = Core::Audit::Record.call(
          audit_key: "ticketing-registration-free-order-confirmed-#{key_digest}",
          action: "ticketing.registration.free_order_confirmed",
          auditable_type: registration.class.name,
          auditable_id: registration.id,
          actor_type: @actor&.class&.name,
          actor_id: @actor&.id,
          audited_changes: {
            status: [ status_before, "confirmed" ],
            confirmed_at: @at.iso8601
          },
          metadata: { order_id: @order_id, source: "zero_total_order" }
        )
        raise result.error if result.failure?
      end
    end
  end
end
