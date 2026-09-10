# frozen_string_literal: true

require "test_helper"

module Marketplace
  module SellerPayoutAccounts
    class VerifyTest < ActiveSupport::TestCase
      include Marketplace::SellerPayoutTestHelpers

      setup do
        setup_seller_payout_context
        @account = create_payout_account(account_number: "1000000000008")
        @actor = core_users(:super_admin)
      end

      test "manually verifies a pending account with audited evidence" do
        result = Verify.call(
          account: @account,
          actor: @actor,
          reason: "Verified against seller-provided bank evidence",
          evidence_reference: "case-2026-09-10-001",
          idempotency_key: "seller-account-verify-1",
          at: @now
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "verified", result.value.status
        assert_equal "manual", result.value.verification_source
        assert_equal @actor.id, result.value.verified_by_id
        assert_equal @now, result.value.verified_at
        audit = Core::AuditLog.find_by!(action: "marketplace.seller_payout_account.verified")
        assert_equal @account.id, audit.metadata.fetch("account_id")
        assert_equal "case-2026-09-10-001", audit.metadata.fetch("evidence_reference")
        refute_includes audit.metadata.keys, "account_number"
        refute_includes audit.metadata.keys, "holder_name"
      end

      test "manual verification is idempotent" do
        subject = -> {
          Verify.call(
            account: @account,
            actor: @actor,
            reason: "Verified against seller-provided bank evidence",
            evidence_reference: "case-2026-09-10-002",
            idempotency_key: "seller-account-verify-2",
            at: @now
          )
        }

        assert_audit_idempotent(
          subject,
          action: "marketplace.seller_payout_account.verified",
          auditable_type: SellerPayoutAccount.name,
          auditable_id: @account.id
        )
      end

      test "requires the dedicated verification permission" do
        result = Verify.call(
          account: @account,
          actor: @seller,
          reason: "Seller cannot self-verify",
          evidence_reference: "case-2026-09-10-003",
          idempotency_key: "seller-account-verify-3",
          at: @now
        )

        assert_predicate result, :failure?
        assert_equal "unauthorized", result.error.code
        assert_equal "pending_verification", @account.reload.status
      end

      test "requires reason and evidence reference" do
        result = Verify.call(
          account: @account,
          actor: @actor,
          reason: "",
          evidence_reference: "",
          idempotency_key: "seller-account-verify-4",
          at: @now
        )

        assert_predicate result, :failure?
        assert_equal "payout_account_verification_required", result.error.code
      end

      test "treats an already verified account as a successful manual-verification no-op" do
        verified = create_payout_account(
          status: "verified", verified_at: @now, account_number: "1000000000009"
        )
        result = Verify.call(
          account: verified,
          actor: @actor,
          reason: "Repeat review",
          evidence_reference: "case-2026-09-10-005",
          idempotency_key: "seller-account-verify-5",
          at: @now
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "verified", result.value.status
      end
    end
  end
end
