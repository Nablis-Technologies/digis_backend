# frozen_string_literal: true

module Marketplace
  module SellerPayoutAccounts
    # Applies the audited Marketplace fallback when Chapa cannot preflight
    # verify a beneficiary. Sellers cannot self-verify payout destinations.
    class Verify < Core::BaseService
      include CommandSupport

      PERMISSION = "marketplace.seller_payout_account.verify"

      def initialize(account:, actor:, reason:, evidence_reference:, idempotency_key:, at: Time.current)
        @account_id = account.id
        @actor = actor
        @reason = reason.to_s.strip
        @evidence_reference = evidence_reference.to_s.strip
        @idempotency_key = idempotency_key
        @at = at.to_time.utc
      end

      def call
        return failure(command_error(:unauthorized, code: "unauthorized", status: :forbidden)) unless actor&.has_permission?(PERMISSION)
        return failure(command_error(:payout_account_verification_required, code: "payout_account_verification_required")) if reason.blank? || evidence_reference.blank?

        key = normalize_command_key(idempotency_key)
        audit_key = command_audit_key("verified", key)
        request_digest = command_request_digest(
          operation: "verify", account_id:, actor:, identity: { reason:, evidence_reference: }
        )
        replay = replay_result(audit_key:, request_digest:)
        return replay if replay

        verified = Marketplace::ApplicationRecord.transaction do
          account = SellerPayoutAccount.lock.find(account_id)
          return success(account) if account.verified?
          return failure(command_error(:payout_account_not_verifiable, code: "payout_account_not_verifiable")) unless account.status == "pending_verification"

          account.update!(
            status: "verified", verification_source: "manual", verified_by: actor,
            verified_at: at, is_default: false
          )
          account.record_audit!(
            "marketplace.seller_payout_account.verified",
            audit_key:,
            audited_changes: {
              status: [ "pending_verification", "verified" ],
              verification_source: [ nil, "manual" ]
            },
            metadata: {
              account_id: account.id, verification_source: "manual", reason:, evidence_reference:,
              idempotency_key: key.to_s, request_digest:
            },
            actor:
          )
          account
        end

        success(verified)
      rescue ArgumentError
        failure(command_error(:idempotency_key_invalid, code: "idempotency_key_invalid"))
      rescue Core::Audit::Record::ReplayConflict
        failure(command_error(:idempotency_conflict, code: "idempotency_conflict", status: :conflict))
      rescue ActiveRecord::RecordNotFound
        failure(command_error(:payout_account_not_found, code: "payout_account_not_found", status: :not_found))
      rescue ActiveRecord::RecordInvalid => invalid
        failure(Core::BusinessError.new(
          I18n.t("marketplace.resale.errors.payout_account_invalid"),
          code: "payout_account_invalid", status: :conflict,
          errors: invalid.record.errors.to_hash
        ))
      end

      private

      attr_reader :account_id, :actor, :reason, :evidence_reference, :idempotency_key, :at
    end
  end
end
