# frozen_string_literal: true

module Finance
  module PayoutAccounts
    # Stops future payout dispatches for a destination while retaining its
    # encrypted record and audit history.
    class Suspend < Core::BaseService
      include CommandSupport

      PERMISSION = "finance.payout_account.verify"

      def initialize(account:, actor:, reason:, idempotency_key:)
        @account_id = account.id
        @actor = actor
        @reason = reason.to_s.strip
        @idempotency_key = idempotency_key
      end

      def call
        return failure(error(:unauthorized, "unauthorized", :forbidden)) unless actor&.has_permission?(PERMISSION)
        return failure(error(:payout_account_verification_required, "payout_account_verification_required")) if reason.blank?

        key = normalize_command_key(idempotency_key)
        audit_key = command_audit_key("suspended", key)
        request_digest = command_request_digest(
          operation: "suspend", account_id:, actor:, identity: { reason: }
        )
        replay = replay_result(audit_key:, request_digest:)
        return replay if replay

        suspended = Finance::ApplicationRecord.transaction do
          account = PayoutAccount.lock.find(account_id)
          return success(account) if account.status == "suspended"
          return failure(error(:payout_account_not_suspendable, "payout_account_not_suspendable")) if account.status == "closed"

          previous_status = account.status
          previous_default = account.is_default
          account.update!(
            status: "suspended", is_default: false,
            verification_source: nil, verified_by: nil, verified_at: nil
          )
          account.record_audit!(
            "finance.payout_account.suspended",
            audit_key:,
            audited_changes: { status: [ previous_status, "suspended" ], is_default: [ previous_default, false ] },
            metadata: { account_id: account.id, reason:, idempotency_key: key.to_s, request_digest: },
            actor:
          )
          account
        end

        success(suspended)
      rescue ArgumentError
        failure(error(:idempotency_key_invalid, "idempotency_key_invalid"))
      rescue Core::Audit::ReplayConflict
        failure(error(:idempotency_conflict, "idempotency_conflict", :conflict))
      end

      private

      attr_reader :account_id, :actor, :reason, :idempotency_key
    end
  end
end
