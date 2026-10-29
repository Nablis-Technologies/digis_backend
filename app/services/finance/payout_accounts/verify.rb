# frozen_string_literal: true

module Finance
  module PayoutAccounts
    # Applies an audited Finance fallback when provider verification is
    # unavailable. Organizers cannot self-verify beneficiary destinations.
    class Verify < Core::BaseService
      include CommandSupport

      PERMISSION = "finance.payout_account.verify"

      def initialize(account:, actor:, reason:, evidence_reference:, idempotency_key:, at: Time.current)
        @account_id = account.id
        @actor = actor
        @reason = reason.to_s.strip
        @evidence_reference = evidence_reference.to_s.strip
        @idempotency_key = idempotency_key
        @at = at.to_time.utc
      end

      def call
        return failure(error(:unauthorized, "unauthorized", :forbidden)) unless actor&.has_permission?(PERMISSION)
        return failure(error(:payout_account_verification_required, "payout_account_verification_required")) if reason.blank? || evidence_reference.blank?

        key = normalize_command_key(idempotency_key)
        audit_key = command_audit_key("verified", key)
        request_digest = command_request_digest(
          operation: "verify", account_id:, actor:, identity: { reason:, evidence_reference: }
        )
        replay = replay_result(audit_key:, request_digest:)
        return replay if replay

        verified = Finance::ApplicationRecord.transaction do
          account = PayoutAccount.lock.find(account_id)
          return success(account) if account.verified?
          return failure(error(:payout_account_not_verifiable, "payout_account_not_verifiable")) unless account.status == "pending_verification"

          account.update!(
            status: "verified", verification_source: "manual", verified_by: actor,
            verified_at: at, is_default: false
          )
          account.record_audit!(
            "finance.payout_account.verified",
            audit_key:,
            audited_changes: { status: [ "pending_verification", "verified" ], verification_source: [ nil, "manual" ] },
            metadata: {
              account_id: account.id, verification_source: "manual",
              reason:, evidence_reference:, idempotency_key: key.to_s, request_digest:
            },
            actor:
          )
          account
        end

        success(verified)
      rescue ArgumentError
        failure(error(:idempotency_key_invalid, "idempotency_key_invalid"))
      rescue Core::Audit::Record::ReplayConflict
        failure(error(:idempotency_conflict, "idempotency_conflict", :conflict))
      rescue ActiveRecord::RecordInvalid => invalid
        failure(Core::BusinessError.new(
          I18n.t("finance.errors.payout_account_invalid"),
          code: "payout_account_invalid", status: :conflict,
          errors: invalid.record.errors.to_hash
        ))
      end

      private

      attr_reader :account_id, :actor, :reason, :evidence_reference, :idempotency_key, :at
    end
  end
end
