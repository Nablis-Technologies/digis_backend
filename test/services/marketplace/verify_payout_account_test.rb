# frozen_string_literal: true

require "test_helper"

module Marketplace
  class VerifyPayoutAccountTest < ActiveSupport::TestCase
    include SellerPayoutTestHelpers

    class FakeAdapter < Marketplace::PayoutProviders::Adapter
      attr_reader :verify_requests, :bank_requests
      attr_accessor :banks, :verification_result

      def initialize
        @verify_requests = []
        @bank_requests = []
        @banks = nil
        @verification_result = Marketplace::PayoutProviders::Result.success(
          provider_reference: "account-verification-1"
        )
      end

      def verify_payout_account(**request)
        @verify_requests << request
        verification_result
      end

      def available_banks(**request)
        @bank_requests << request
        banks
      end

      def payout(**) = Marketplace::PayoutProviders::Result.unknown(raw_status: "unused")

      def verify_payout(**) = Marketplace::PayoutProviders::Result.unknown(raw_status: "unused")

      def available_balance(**) = { amount_minor: 100_000, currency: "ETB" }

      def capabilities = { payouts: { supported: true } }
    end

    setup do
      setup_seller_payout_context
      @adapter = FakeAdapter.new
    end

    test "stores encrypted direct beneficiary values" do
      result = VerifyPayoutAccount.call(
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000005",
        account_label: "Telebirr wallet",
        holder_name: "Seller Holder",
        adapter: @adapter,
        idempotency_key: "verify-account-1",
        at: @now
      )

      assert_predicate result, :success?, result.error&.message
      account = result.value
      assert_equal "verified", account.status
      assert_equal "1000000000005", account.account_number
      assert_equal "cbe", account.bank_slug
      assert_equal "Seller Holder", account.holder_name
      assert_equal "Telebirr wallet", account.account_label
      stored = SellerPayoutAccount.connection.select_value(
        "SELECT account_number_ciphertext FROM marketplace_seller_payout_accounts WHERE id = '#{account.id}'"
      )
      refute_equal "1000000000005", stored
      refute_includes account.attributes.keys, "account_number"
      refute_includes SellerPayoutAccount.ransackable_attributes, "account_number_digest"
      refute_includes SellerPayoutAccount.ransackable_attributes, "holder_name_ciphertext"
      assert_equal "1000000000005", @adapter.verify_requests.first.fetch(:account_number)
      assert_equal "cbe", @adapter.verify_requests.first.fetch(:bank_slug)
      assert_equal [ { country: "ET" } ], @adapter.bank_requests
    end

    test "returns an unresolved account as pending without marking it verified" do
      @adapter.verification_result = Marketplace::PayoutProviders::Result.timeout(raw_status: "timeout")

      result = VerifyPayoutAccount.call(
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000002",
        account_label: "Pending wallet",
        holder_name: "Seller Holder",
        adapter: @adapter,
        idempotency_key: "verify-account-timeout",
        at: @now
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "pending_verification", result.value.status
      account = SellerPayoutAccount.find_by!(user: @seller, status: "pending_verification")
      assert_equal "pending_verification", account.status
      assert_nil account.verified_at
    end

    test "replays a successful verification without calling the provider again" do
      arguments = {
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000003",
        account_label: "Replay wallet",
        holder_name: "Seller Holder",
        adapter: @adapter,
        idempotency_key: "verify-account-replay",
        at: @now
      }

      first = VerifyPayoutAccount.call(**arguments)
      second = VerifyPayoutAccount.call(**arguments)

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :success?, second.error&.message
      assert_equal first.value.id, second.value.id
      assert_equal 1, @adapter.verify_requests.size
    end

    test "rejects a bank slug absent from the provider bank list" do
      @adapter.banks = [ { bank_slug: "other" } ]

      result = VerifyPayoutAccount.call(
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000004",
        holder_name: "Seller Holder",
        adapter: @adapter,
        idempotency_key: "verify-account-bank-error",
        at: @now
      )

      assert_predicate result, :failure?
      assert_equal "payout_account_bank_unsupported", result.error.code
      digest = Core::PayoutAccountDigest.call(namespace: @seller.id, account_number: "1000000000004")
      assert_not SellerPayoutAccount.exists?(user: @seller, account_number_digest: digest)
    end

    test "matches provider bank slugs case-insensitively" do
      @adapter.banks = [ { bank_slug: "CBE" } ]

      result = VerifyPayoutAccount.call(
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000018",
        holder_name: "Seller Holder",
        adapter: @adapter,
        idempotency_key: "verify-account-bank-case",
        at: @now
      )

      assert_predicate result, :success?, result.error&.message
    end

    test "allows a guarded test fixture to be verified without a provider call" do
      result = VerifyPayoutAccount.call(
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000014",
        holder_name: "Preview Seller",
        adapter: @adapter,
        verification_source: "test_fixture",
        idempotency_key: "verify-account-fixture",
        at: @now
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "verified", result.value.status
      assert_equal "test_fixture", result.value.verification_source
      assert_equal @now, result.value.verified_at
      assert_empty @adapter.verify_requests
      assert_equal 1, Core::AuditLog.where(
        auditable_type: SellerPayoutAccount.name,
        auditable_id: result.value.id,
        action: "marketplace.seller_payout_account.verified"
      ).count
    end

    test "replays a registration before consulting a changed bank list" do
      @adapter.banks = [ { bank_slug: "cbe" } ]
      arguments = {
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000016",
        holder_name: "Replay Seller",
        adapter: @adapter,
        idempotency_key: "verify-account-bank-replay",
        at: @now
      }

      first = VerifyPayoutAccount.call(**arguments)
      @adapter.banks = [ { bank_slug: "other" } ]
      replay = VerifyPayoutAccount.call(**arguments)

      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :success?, replay.error&.message
      assert_equal first.value.id, replay.value.id
      assert_equal 1, @adapter.verify_requests.size
    end

    test "does not persist a destination when provider verification definitively fails" do
      @adapter.verification_result = Marketplace::PayoutProviders::Result.failure(
        failure_code: "account_invalid"
      )

      result = VerifyPayoutAccount.call(
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000017",
        holder_name: "Rejected Seller",
        adapter: @adapter,
        idempotency_key: "verify-account-provider-failure",
        at: @now
      )

      assert_predicate result, :failure?
      assert_equal "account_invalid", result.error.code
      digest = Core::PayoutAccountDigest.call(namespace: @seller.id, account_number: "1000000000017")
      assert_not SellerPayoutAccount.exists?(user: @seller, account_number_digest: digest)
    end

    test "returns the original provider failure on a retry without masking it as pending success" do
      @adapter.verification_result = Marketplace::PayoutProviders::Result.failure(
        failure_code: "account_invalid"
      )
      arguments = {
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000018",
        holder_name: "Retry Seller",
        adapter: @adapter,
        idempotency_key: "verify-account-provider-retry",
        at: @now
      }

      first = VerifyPayoutAccount.call(**arguments)
      replay = VerifyPayoutAccount.call(**arguments)

      assert_predicate first, :failure?
      assert_predicate replay, :failure?
      assert_equal "account_invalid", first.error.code
      assert_equal "account_invalid", replay.error.code
      assert_equal 2, @adapter.verify_requests.size
    end

    test "returns an idempotency conflict when the audit recorder detects a replay conflict" do
      Core::Audit::Record.stubs(:call).raises(Core::Audit::Record::ReplayConflict)

      result = VerifyPayoutAccount.call(
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000019",
        holder_name: "Conflict Seller",
        adapter: @adapter,
        idempotency_key: "verify-account-audit-conflict",
        at: @now
      )

      assert_predicate result, :failure?
      assert_equal "idempotency_conflict", result.error.code
    end

    test "resolves a replay before validating a changed malformed payload" do
      arguments = {
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000021",
        holder_name: "Replay Seller",
        adapter: @adapter,
        idempotency_key: "verify-account-malformed-replay",
        at: @now
      }

      first = VerifyPayoutAccount.call(**arguments)
      replay = VerifyPayoutAccount.call(**arguments.merge(account_number: nil))

      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :failure?
      assert_equal "idempotency_conflict", replay.error.code
    end

    test "returns typed input failure when the seller is missing" do
      result = VerifyPayoutAccount.call(
        user: nil,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000020",
        holder_name: "Missing Seller",
        adapter: @adapter,
        idempotency_key: "verify-account-missing-user",
        at: @now
      )

      assert_predicate result, :failure?
      assert_equal "payout_account_input_invalid", result.error.code
    end
  end
end
