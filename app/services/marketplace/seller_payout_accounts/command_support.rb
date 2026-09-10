# frozen_string_literal: true

module Marketplace
  module SellerPayoutAccounts
    # Centralizes seller payout-account command identity. Audit keys provide
    # the durable idempotency boundary while request digests reject a key
    # replayed for a different seller-account operation.
    module CommandSupport
      include Core::PayoutCommandSupport

      private

      def payout_command_audit_prefix
        "marketplace-seller-payout-account"
      end

      def payout_command_identity_namespace
        "marketplace-seller-payout-account-idempotency"
      end

      def replay_account(audit)
        account = ::Marketplace::SellerPayoutAccount.find_by(
          id: audit.metadata.deep_symbolize_keys[:account_id]
        )
        return success(account) if account

        failure(command_error(
          :payout_account_replay_missing, code: "payout_account_replay_missing", status: :conflict
        ))
      end

      def command_error(key, code: key.to_s, status: :unprocessable_entity, errors: nil)
        Core::BusinessError.new(I18n.t("marketplace.resale.errors.#{key}"), code:, status:, errors:)
      end
    end
  end
end
