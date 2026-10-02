# frozen_string_literal: true

module Marketplace
  module SellerPayouts
    # Reuses Core's audited command identity while keeping payout replay lookup
    # local to the Marketplace aggregate.
    module CommandSupport
      include Core::PayoutCommandSupport

      private

      def payout_command_audit_prefix
        "marketplace-seller-payout"
      end

      def payout_command_identity_namespace
        "marketplace-seller-payout-idempotency"
      end

      def replay_target(audit)
        payout = SellerPayout.find_by(id: audit.metadata.deep_symbolize_keys[:payout_id])
        return success(payout) if payout

        failure(command_error(
          :seller_payout_replay_missing, code: "seller_payout_replay_missing", status: :conflict
        ))
      end

      def command_error(key, code: key.to_s, status: :unprocessable_entity, errors: nil)
        Core::BusinessError.new(I18n.t("marketplace.resale.errors.#{key}"), code:, status:, errors:)
      end
    end
  end
end
