# frozen_string_literal: true

require "test_helper"

module Marketplace
  class VerifyPayoutAccountTest < ActiveSupport::TestCase
    include SellerPayoutTestHelpers

    class FakeAdapter < Marketplace::PayoutProviders::Adapter
      attr_reader :tokenize_requests, :verify_requests
      attr_accessor :verification_result

      def initialize
        @tokenize_requests = []
        @verify_requests = []
        @verification_result = Marketplace::PayoutProviders::Result.success(
          provider_reference: "account-verification-1"
        )
      end

      def tokenize_payout_account(**request)
        @tokenize_requests << request
        {
          account_token: "provider-token-#{SecureRandom.hex(6)}",
          account_label: "Telebirr •••• 1234",
          holder_name: request.fetch(:holder_name)
        }
      end

      def verify_payout_account(**request)
        @verify_requests << request
        verification_result
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

    test "stores only the provider token and encrypted display values" do
      result = VerifyPayoutAccount.call(
        user: @seller,
        type: "mobile_money",
        provider: "telebirr",
        account_details: { phone: "+251911111111", pin: "raw-secret" },
        account_label: "Telebirr wallet",
        holder_name: "Seller Holder",
        adapter: @adapter,
        idempotency_key: "verify-account-1",
        at: @now
      )

      assert_predicate result, :success?, result.error&.message
      account = result.value
      assert_equal "verified", account.status
      assert_match(/\Aprovider-token-[0-9a-f]+\z/, account.account_token)
      assert_equal "Seller Holder", account.holder_name_ciphertext
      assert_equal "Telebirr wallet", account.account_label_ciphertext
      stored = SellerPayoutAccount.connection.select_value(
        "SELECT holder_name_ciphertext FROM marketplace_seller_payout_accounts WHERE id = '#{account.id}'"
      )
      refute_equal "Seller Holder", stored
      refute_includes account.attributes.keys, "account_details"
      refute_includes SellerPayoutAccount.ransackable_attributes, "account_token"
      refute_includes SellerPayoutAccount.ransackable_attributes, "holder_name_ciphertext"
      assert_equal account.account_token, @adapter.verify_requests.first.fetch(:account_token)
      assert_equal "+251911111111", @adapter.tokenize_requests.first.fetch(:account_details).fetch(:phone)
    end

    test "leaves an unresolved account pending and never marks it verified" do
      @adapter.verification_result = Marketplace::PayoutProviders::Result.timeout(raw_status: "timeout")

      result = VerifyPayoutAccount.call(
        user: @seller,
        type: "mobile_money",
        provider: "telebirr",
        account_details: { phone: "+251922222222" },
        account_label: "Pending wallet",
        holder_name: "Seller Holder",
        adapter: @adapter,
        idempotency_key: "verify-account-timeout",
        at: @now
      )

      assert_predicate result, :failure?
      assert_equal "payout_account_verification_pending", result.error.code
      account = SellerPayoutAccount.find_by!(user: @seller, status: "pending_verification")
      assert_equal "pending_verification", account.status
      assert_nil account.verified_at
    end

    test "replays a successful verification without calling the provider again" do
      arguments = {
        user: @seller,
        type: "mobile_money",
        provider: "telebirr",
        account_details: { phone: "+251933333333" },
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
      assert_equal 1, @adapter.tokenize_requests.size
      assert_equal 1, @adapter.verify_requests.size
    end
  end
end
