# frozen_string_literal: true

require "test_helper"

module Finance
  module PayoutAccounts
    class LifecycleTest < ActiveSupport::TestCase
      setup do
        @organization = organizations_organizations(:one)
        @actor = core_users(:super_admin)
        @account = create_account
      end

      test "finance verifies a pending account with an audited manual fallback" do
        result = Verify.call(
          account: @account,
          actor: @actor,
          reason: "Confirmed in Chapa dashboard",
          evidence_reference: "chapa-case-1",
          idempotency_key: "payout-account-verify-1"
        )

        assert_predicate result, :success?, result.error&.message
        assert_predicate result.value.reload, :verified?
        assert_equal "manual", result.value.verification_source
        assert_equal @actor.id, result.value.verified_by_id
        assert_equal 1, Core::AuditLog.where(action: "finance.payout_account.verified").count
      end

      test "verification rejects an unauthorized actor" do
        result = Verify.call(
          account: @account,
          actor: core_users(:attendee),
          reason: "Not allowed",
          evidence_reference: "case-2",
          idempotency_key: "payout-account-verify-2"
        )

        assert_predicate result, :failure?
        assert_equal "unauthorized", result.error.code
      end

      test "verification rejects a key reused with different evidence" do
        first = Verify.call(
          account: @account,
          actor: @actor,
          reason: "Confirmed",
          evidence_reference: "case-1",
          idempotency_key: "payout-account-verify-conflict"
        )
        second = Verify.call(
          account: @account,
          actor: @actor,
          reason: "Confirmed again",
          evidence_reference: "case-2",
          idempotency_key: "payout-account-verify-conflict"
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal "idempotency_conflict", second.error.code
      end

      test "sets one verified account as the organization default" do
        @account.update!(
          status: "verified", verification_source: "test_fixture", verified_at: Time.current
        )

        result = SetDefault.call(
          account: @account,
          actor: @actor,
          idempotency_key: "payout-account-default-1"
        )

        assert_predicate result, :success?, result.error&.message
        assert_predicate result.value.reload, :is_default?
      end

      test "clears the previous default before selecting a replacement" do
        @account.update!(
          status: "verified", verification_source: "test_fixture",
          verified_at: Time.current, is_default: true
        )
        replacement = create_account(number: "1000000000002")
        replacement.update!(
          status: "verified", verification_source: "test_fixture", verified_at: Time.current
        )

        result = SetDefault.call(
          account: replacement,
          actor: @actor,
          idempotency_key: "payout-account-default-replacement"
        )

        assert_predicate result, :success?, result.error&.message
        assert_not @account.reload.is_default?
        assert_predicate replacement.reload, :is_default?
      end

      test "default selection rejects a key reused for another account" do
        @account.update!(
          status: "verified", verification_source: "test_fixture", verified_at: Time.current
        )
        replacement = create_account(number: "1000000000002")
        replacement.update!(
          status: "verified", verification_source: "test_fixture", verified_at: Time.current
        )

        first = SetDefault.call(
          account: @account,
          actor: @actor,
          idempotency_key: "payout-account-default-conflict"
        )
        second = SetDefault.call(
          account: replacement,
          actor: @actor,
          idempotency_key: "payout-account-default-conflict"
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal "idempotency_conflict", second.error.code
      end

      test "suspending a default account clears its dispatch eligibility" do
        @account.update!(
          status: "verified", verification_source: "test_fixture",
          verified_at: Time.current, is_default: true
        )

        result = Suspend.call(
          account: @account,
          actor: @actor,
          reason: "Destination review required",
          idempotency_key: "payout-account-suspend-1"
        )

        assert_predicate result, :success?, result.error&.message
        assert_equal "suspended", result.value.reload.status
        assert_not result.value.is_default?
      end

      test "closing a default account is rejected until another default is selected" do
        @account.update!(
          status: "verified", verification_source: "test_fixture",
          verified_at: Time.current, is_default: true
        )

        result = Close.call(
          account: @account,
          actor: @actor,
          reason: "Close requested",
          idempotency_key: "payout-account-close-1"
        )

        assert_predicate result, :failure?
        assert_equal "payout_account_default", result.error.code
      end

      test "suspension rejects a key reused with a different reason" do
        first = Suspend.call(
          account: @account,
          actor: @actor,
          reason: "First review",
          idempotency_key: "payout-account-suspend-conflict"
        )
        second = Suspend.call(
          account: @account,
          actor: @actor,
          reason: "Second review",
          idempotency_key: "payout-account-suspend-conflict"
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal "idempotency_conflict", second.error.code
      end

      test "closure rejects a key reused with a different reason" do
        first = Close.call(
          account: @account,
          actor: @actor,
          reason: "First closure",
          idempotency_key: "payout-account-close-conflict"
        )
        second = Close.call(
          account: @account,
          actor: @actor,
          reason: "Second closure",
          idempotency_key: "payout-account-close-conflict"
        )

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal "idempotency_conflict", second.error.code
      end

      private

      def create_account(number: "1000000000001")
        PayoutAccount.create!(
          organization: @organization,
          type: "bank",
          provider: "chapa",
          bank_code: 128,
          account_number: number,
          account_name: "Digis Organizer",
          account_number_digest: Core::KeyedDigest.digest(
            namespace: @organization.id, value: number
          )
        )
      end
    end
  end
end
