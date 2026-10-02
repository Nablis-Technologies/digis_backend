# frozen_string_literal: true

module Finance
  module PayoutAccounts
    # Centralizes payout-destination command identity. The audit key is the
    # database-backed idempotency boundary; the request digest prevents a
    # client from replaying the same key against a different destination or
    # lifecycle intent.
    module CommandSupport
      include Core::PayoutCommandSupport

      private

      def payout_command_audit_prefix
        "finance-payout-account"
      end

      def payout_command_identity_namespace
        "finance-payout-account-idempotency"
      end

      def replay_target(audit)
        account_id = audit.metadata.deep_symbolize_keys[:account_id]
        account = PayoutAccount.find_by(id: account_id)
        return success(account) if account

        failure(command_error(
          :payout_account_replay_missing,
          code: "payout_account_replay_missing", status: :conflict
        ))
      end

      def command_error(key, code: key.to_s, status: :unprocessable_entity, errors: nil)
        Core::BusinessError.new(I18n.t("finance.errors.#{key}"), code:, status:, errors:)
      end

      def finance_error(key, code: key, status: :unprocessable_entity, errors: nil)
        command_error(key, code:, status:, errors:)
      end

      def error(key, code, status = :unprocessable_entity)
        command_error(key, code:, status:)
      end
    end
  end
end
