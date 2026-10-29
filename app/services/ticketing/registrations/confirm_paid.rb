# frozen_string_literal: true

module Ticketing
  module Registrations
    # Confirms a registration only after its linked event payment is accepted.
    # Paid ticket issuance remains owned by the order-item fulfillment outbox.
    class ConfirmPaid < Core::BaseService
      def initialize(registration:, payment:, at: Time.current)
        @registration_id = registration.id
        @payment_id = payment.id
        @at = at.to_time.utc
      end

      def call
        Registration.transaction do
          registration = Registration.lock.find(@registration_id)
          next success(registration) if registration.confirmed?
          next failure(error(:registration_not_confirmable)) unless registration.pending_payment?
          next failure(error(:event_payment_required)) unless payment_is_for_registration?

          registration.update!(status: "confirmed", confirmed_at: @at, next_action_snapshot: nil)
          audit = Core::Audit::Record.call(
            action: "ticketing.registration.paid_confirmed",
            auditable_type: "Ticketing::Registration",
            auditable_id: registration.id,
            audited_changes: {
              status: [ "pending_payment", "confirmed" ],
              confirmed_at: @at.iso8601
            },
            metadata: { payment_id: @payment_id, source: "accepted_payment" },
            audit_key: "ticketing-registration-paid-confirmed-#{@payment_id}-#{registration.id}"
          )
          raise audit.error if audit.failure?
          success(registration)
        end
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_registration, message: exception.message))
      end

      private

      def payment_is_for_registration?
        Orders::OrderItem.where(
          registration_id: @registration_id,
          order_id: Orders::Payment.where(id: @payment_id).select(:order_id)
        ).exists?
      end

      def error(key, message: nil)
        Core::BusinessError.new(
          message || I18n.t("ticketing.registration_workflows.errors.#{key}"),
          code: key.to_s,
          status: :conflict
        )
      end
    end
  end
end
