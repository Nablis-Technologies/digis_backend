# frozen_string_literal: true

module Messaging
  module CreditRates
    # Closes an active rate without rewriting its historical definition.
    # Retirement is audit-keyed so a repeated command returns the same state.
    class Retire < Core::BaseService
      include CommandSupport

      PERMISSION = "messaging_credit_rate.retire"

      def initialize(rate:, actor:, idempotency_key:, at: Time.current)
        @rate = rate
        @actor = actor
        @raw_idempotency_key = idempotency_key
        @at = at.to_time
      end

      def call
        return failure(error(:unauthorized, status: :forbidden)) unless authorized?(PERMISSION)

        handle_errors do
          rate = CreditRateVersion.lock.find(@rate.id)
          audit_key = "messaging-credit-rate-retire-#{idempotency_digest}"
          existing_audit = Core::AuditLog.find_by(audit_key:)
          if existing_audit
            return success(rate) if existing_audit.auditable_id == rate.id.to_s &&
              existing_audit.action == "messaging.credit_rate.retired"

            return failure(error(:credit_idempotency_conflict, status: :conflict))
          end
          return success(rate) if rate.retired?
          return failure(error(:rate_not_active, status: :conflict)) unless rate.active?

          rate.update!(status: "retired", retired_by: @actor, retired_at: @at)
          audit!(
            key: audit_key,
            action: "messaging.credit_rate.retired", rate:,
            changes: { "status" => [ "active", "retired" ] }
          )
          success(rate)
        end
      end
    end
  end
end
