# frozen_string_literal: true

require "test_helper"

module Marketplace
  module PayoutProviders
    class ChapaAdapterTest < ActiveSupport::TestCase
      class FakeClient
        attr_reader :payout_requests

        def initialize
          @payout_requests = []
        end

        def payout(**request)
          payout_requests << request
          Result.success(provider_reference: "chapa-seller-payout-1")
        end

        def verify_payout(**)
          Result.success(provider_reference: "chapa-seller-payout-1")
        end

        def available_balance(**) = { amount_minor: 100_000, currency: "ETB" }

        def available_banks = [ { bank_slug: "cbe" }, { bank_slug: "awash" } ]

        def capabilities = { payouts: { supported: true } }
      end

      test "delegates direct payout fields to the Chapa client" do
        client = FakeClient.new
        adapter = ChapaAdapter.new(client:)

        result = adapter.payout(
          amount_minor: 1_250,
          currency: "ETB",
          account_number: "1000000000001",
          account_name: "Seller Holder",
          bank_slug: "cbe",
          idempotency_key: "seller-payout-1"
        )

        assert_predicate result, :success?
        assert_equal "1000000000001", client.payout_requests.sole.fetch(:account_number)
        assert_equal "Seller Holder", client.payout_requests.sole.fetch(:account_name)
        assert_equal "cbe", client.payout_requests.sole.fetch(:bank_slug)
        refute client.payout_requests.sole.key?(:destination_token)
      end

      test "exposes bank slugs and leaves unsupported preflight verification unknown" do
        adapter = ChapaAdapter.new(client: FakeClient.new)

        assert_equal [ { bank_slug: "cbe" }, { bank_slug: "awash" } ], adapter.available_banks
        result = adapter.verify_payout_account(account_number: "1000000000001", bank_slug: "cbe")
        assert_predicate result, :unknown?
        assert_equal "unsupported", result.raw_status
      end
    end
  end
end
