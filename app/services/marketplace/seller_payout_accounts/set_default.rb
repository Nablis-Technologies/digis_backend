# frozen_string_literal: true

module Marketplace
  module SellerPayoutAccounts
    # Atomically selects one verified seller destination as the default without
    # retargeting any existing payout intent.
    class SetDefault < Core::BaseService
      include CommandSupport

      def initialize(account:, actor:, idempotency_key:)
        @account_id = account.id
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        account = SellerPayoutAccount.find(account_id)
        return failure(command_error(:unauthorized, code: "unauthorized", status: :forbidden)) unless account_access?(account)
        return failure(command_error(:payout_account_not_verifiable, code: "payout_account_not_verifiable")) unless account.verified?

        key = normalize_command_key(idempotency_key)
        audit_key = command_audit_key("default", key)
        request_digest = command_request_digest(operation: "set_default", account_id:, actor:)
        replay = replay_result(audit_key:, request_digest:)
        return replay if replay

        selected = Marketplace::ApplicationRecord.transaction do
          Core::User.lock.find(account.user_id)
          selected = SellerPayoutAccount.lock.find_by(id: account_id, user_id: account.user_id)
          return failure(command_error(:payout_account_not_found, code: "payout_account_not_found", status: :not_found)) unless selected
          return failure(command_error(:unauthorized, code: "unauthorized", status: :forbidden)) unless account_access?(selected)
          return failure(command_error(:payout_account_not_verifiable, code: "payout_account_not_verifiable")) unless selected.verified?

          SellerPayoutAccount.where(user_id: selected.user_id, provider: selected.provider)
            .where.not(id: selected.id).where(is_default: true).update_all(is_default: false)
          selected.update!(is_default: true)
          selected.record_audit!(
            "marketplace.seller_payout_account.default_selected",
            audit_key:,
            audited_changes: { is_default: [ false, true ] },
            metadata: { account_id: selected.id, idempotency_key: key.to_s, request_digest: },
            actor:
          )
          selected
        end

        success(selected)
      rescue ArgumentError
        failure(command_error(:idempotency_key_invalid, code: "idempotency_key_invalid"))
      rescue Core::Audit::Record::ReplayConflict
        failure(command_error(:idempotency_conflict, code: "idempotency_conflict", status: :conflict))
      rescue ActiveRecord::RecordNotFound
        failure(command_error(:payout_account_not_found, code: "payout_account_not_found", status: :not_found))
      end

      private

      attr_reader :account_id, :actor, :idempotency_key

      def account_access?(account)
        account.user_id == actor&.id || platform_admin?
      end

      def platform_admin?
        actor&.super_admin? || actor&.has_role?("ADMIN") || actor&.has_role?("CORE_ADMIN")
      end
    end
  end
end
