# frozen_string_literal: true

module Finance
  module PayoutAccounts
    # Atomically selects one verified organization destination as default.
    class SetDefault < Core::BaseService
      include CommandSupport

      def initialize(account:, actor:, idempotency_key:)
        @account_id = account.id
        @actor = actor
        @idempotency_key = idempotency_key
      end

      def call
        account = PayoutAccount.includes(:organization).find(account_id)
        return failure(error(:unauthorized, "unauthorized", :forbidden)) unless Events::AuthorizationResolver.organization_admin?(actor, account.organization)
        return failure(error(:payout_account_not_verifiable, "payout_account_not_verifiable")) unless account.verified?

        key = normalize_command_key(idempotency_key)
        audit_key = command_audit_key("default", key)
        request_digest = command_request_digest(
          operation: "set_default", account_id:, actor:
        )
        replay = replay_result(audit_key:, request_digest:)
        return replay if replay

        selected = Finance::ApplicationRecord.transaction do
          organization = Organizations::Organization.lock.find(account.organization_id)
          selected = PayoutAccount.lock.find_by(id: account_id, organization_id: organization.id)
          return failure(error(:payout_account_not_found, "payout_account_not_found", :not_found)) unless selected
          return failure(error(:payout_account_not_verifiable, "payout_account_not_verifiable")) unless selected.verified?

          # The organization lock serializes default changes; the partial
          # unique index remains the database backstop.
          PayoutAccount.where(organization_id: organization.id).where.not(id: selected.id)
            .where(is_default: true).update_all(is_default: false)
          selected.update!(is_default: true)
          selected.record_audit!(
            "finance.payout_account.default_selected",
            audit_key:,
            audited_changes: { is_default: [ false, true ] },
            metadata: { account_id: selected.id, idempotency_key: key.to_s, request_digest: },
            actor:
          )
          selected
        end

        success(selected)
      rescue ArgumentError
        failure(error(:idempotency_key_invalid, "idempotency_key_invalid"))
      rescue Core::Audit::Record::ReplayConflict
        failure(error(:idempotency_conflict, "idempotency_conflict", :conflict))
      end

      private

      attr_reader :account_id, :actor, :idempotency_key
    end
  end
end
