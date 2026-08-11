# frozen_string_literal: true

module Commercial
  module Subsidies
    # Shared locking, error, and evidence mechanics for subsidy commands.
    # Every command locks the budget before the reservation, matching the
    # platform-wide commercial lock order and preventing budget deadlocks.
    module Support
      include Commercial::Governance::CommandSupport

      private

      def subsidy_error(key, code: key, status: :unprocessable_entity, errors: nil, **options)
        Core::BusinessError.new(
          I18n.t("commercial.subsidies.errors.#{key}", **options),
          code:, status:, errors:
        )
      end

      def invalid_idempotency_error
        Core::BusinessError.new(
          I18n.t("commercial.governance.errors.invalid_idempotency_key"),
          code: "invalid_idempotency_key",
          status: :unprocessable_entity
        )
      end

      def invalid_record_error(exception)
        Core::BusinessError.new(
          I18n.t("commercial.governance.errors.invalid_record"),
          code: "invalid_record",
          status: :unprocessable_entity,
          errors: exception.record.errors.to_hash
        )
      end

      def lock_reservation!(reservation_or_id)
        reservation_id = reservation_or_id.respond_to?(:id) ? reservation_or_id.id : reservation_or_id
        budget_id = Commercial::SubsidyReservation.where(id: reservation_id).pick(:subsidy_budget_id)
        raise ActiveRecord::RecordNotFound if budget_id.blank?

        budget = Commercial::SubsidyBudget.lock.find(budget_id)
        reservation = Commercial::SubsidyReservation.lock.find(reservation_id)
        [ reservation, budget ]
      end

      def record_subsidy_transition!(reservation:, from:, to:, action:, audit_key:, reason: nil,
        timestamp_attribute: nil)
        metadata = {
          "request_fingerprint" => reservation.request_fingerprint,
          "idempotency_key_digest" => reservation.idempotency_key_digest
        }
        metadata["reason"] = reason if reason.present?
        audited_changes = { "status" => [ from, to ] }
        if timestamp_attribute
          audited_changes[timestamp_attribute.to_s] = [ nil, reservation.public_send(timestamp_attribute) ]
        end

        record_transition!(
          target: reservation,
          actor: nil,
          audit_key:,
          action:,
          audited_changes:,
          metadata:,
          topic: "commercial",
          event_type: action,
          payload: {
            subsidy_reservation_id: reservation.id,
            subsidy_budget_id: reservation.subsidy_budget_id,
            order_id: reservation.order_id,
            amount_minor: reservation.amount_minor,
            currency: reservation.currency,
            status: reservation.status
          }
        )
      end

      def reservation_transition_audit_key(reservation, target_status)
        "commercial-subsidy-reservation-#{reservation.id}-#{target_status}"
      end
    end
  end
end
