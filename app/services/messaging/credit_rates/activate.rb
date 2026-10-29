# frozen_string_literal: true

module Messaging
  module CreditRates
    # Moves one draft rate into the active set after serializing the scope
    # check. The advisory lock prevents two overlapping versions from becoming
    # active concurrently, while the audit key makes retries no-ops.
    class Activate < Core::BaseService
      include CommandSupport

      PERMISSION = "messaging_credit_rate.activate"

      def initialize(rate:, actor:, idempotency_key:, at: Time.current)
        @rate = rate
        @actor = actor
        @raw_idempotency_key = idempotency_key
        @at = at.to_time
      end

      def call
        return failure(error(:unauthorized, status: :forbidden)) unless authorized?(PERMISSION)

        handle_errors do
          ActiveRecord::Base.transaction do
            rate = CreditRateVersion.lock.find(@rate.id)
            # Serialize activation by the full rate scope, not just the row;
            # overlap validation must see the same active set for every writer.
            Core::Database::AdvisoryLock.acquire!(
              "messaging-credit-rate-activate", rate.organization_id || "global",
              rate.channel, rate.currency, rate.country_code || "default"
            )
            audit_key = "messaging-credit-rate-activate-#{idempotency_digest}"
            existing_audit = Core::AuditLog.find_by(audit_key:)
            if existing_audit
              return success(rate) if existing_audit.auditable_id == rate.id.to_s &&
                existing_audit.action == "messaging.credit_rate.activated"

              return failure(error(:credit_idempotency_conflict, status: :conflict))
            end
            return success(rate) if rate.active?
            return failure(error(:rate_not_draft, status: :conflict)) unless rate.draft?
            return failure(error(:rate_overlap, status: :conflict)) if overlapping_rate?(rate)

            rate.update!(status: "active", activated_by: @actor, activated_at: @at)
            audit!(
              key: audit_key,
              action: "messaging.credit_rate.activated", rate:,
              changes: { "status" => [ "draft", "active" ] }
            )
            success(rate)
          end
        end
      end

      private

      def overlapping_rate?(rate)
        CreditRateVersion.where(status: "active").where(
          organization_id: rate.organization_id, channel: rate.channel,
          currency: rate.currency, country_code: rate.country_code
        ).any? { |other| intervals_overlap?(rate, other) }
      end

      def intervals_overlap?(left, right)
        left_end = left.effective_until || Float::INFINITY
        right_end = right.effective_until || Float::INFINITY
        left.effective_from < right_end && right.effective_from < left_end
      end
    end
  end
end
