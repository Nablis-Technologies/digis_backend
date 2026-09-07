# frozen_string_literal: true

module Messaging
  module Campaigns
    module CreditHolds
      # Shared terminal-state, replay, and ledger-identity rules for settlement.
      module SettlementSupport
        OUTCOMES = %i[delivered suppressed failed retryable].freeze
        TERMINAL_STATUSES = {
          delivered: "consumed",
          suppressed: "released",
          failed: "refunded"
        }.freeze

        private

        def settlement_for(outcome:, quantity:, reason: nil)
          case outcome.to_sym
          when :delivered then [ "consumed", "consume", 0, "delivered" ]
          when :suppressed then [ "released", "release", quantity, reason.presence || "suppressed" ]
          else [ "refunded", "refund", quantity, reason.presence || "provider_failed" ]
          end
        end

        def terminal_status_for(outcome)
          TERMINAL_STATUSES.fetch(outcome.to_sym)
        end

        def settlement_operation(allocation:, outcome:)
          "campaign-allocation-#{allocation.id}-#{outcome}"
        end

        def settlement_ledger_digest(allocation:, outcome:)
          Core::KeyedDigest.digest(
            namespace: "messaging-campaign-settlement",
            value: "#{allocation.id}:#{outcome}"
          )
        end

        def settlement_conflict
          Core::BusinessError.new(
            I18n.t("messaging.errors.credit_idempotency_conflict"),
            code: "credit_idempotency_conflict", status: :conflict
          )
        end
      end
    end
  end
end
