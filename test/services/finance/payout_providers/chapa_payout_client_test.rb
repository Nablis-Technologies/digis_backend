# frozen_string_literal: true

require "json"
require "test_helper"

module Finance
  module PayoutProviders
    class ChapaPayoutClientTest < ActiveSupport::TestCase
      Response = Data.define(:status, :body)

      class FakeTransport
        attr_reader :requests

        def initialize(*responses)
          @responses = responses
          @requests = []
        end

        def call(method:, path:, headers:, body: nil)
          @requests << { method:, path:, headers:, body: }
          @responses.shift || Response.new(status: 200, body: {})
        end
      end

      test "initializes a V2 payout with a bank slug and native idempotency" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success",
            data: { chapa_reference: "PAYOUT-V2-1", status: "pending" }
          })
        )

        result = build_client(transport:).payout(
          amount_minor: 1_250,
          currency: "ETB",
          account_number: "1000000000001",
          account_name: "Seller Account",
          bank_slug: "cbe",
          bank_name: "Commercial Bank of Ethiopia",
          idempotency_key: "seller-payout-v2-1"
        )

        assert_predicate result, :unknown?
        assert_equal "PAYOUT-V2-1", result.provider_reference
        assert_nil result.failure_code
        request = transport.requests.sole
        assert_equal :post, request.fetch(:method)
        assert_equal "/v2/payouts", request.fetch(:path)
        assert_equal "Bearer CHAPA_TEST_secret", request.dig(:headers, "Authorization")
        assert_equal "seller-payout-v2-1", request.dig(:headers, "Idempotency-Key")
        payload = JSON.parse(request.fetch(:body))
        assert_equal 12.5, payload.fetch("amount")
        assert_equal "seller-payout-v2-1", payload.fetch("merchant_reference")
        assert_equal "cbe", payload.dig("account", "bank_slug")
      end

      test "serializes large minor amounts without floating point loss" do
        transport = FakeTransport.new(Response.new(status: 200, body: { status: "success", data: {} }))

        build_client(transport:).payout(
          amount_minor: 9_007_199_254_740_993, currency: "ETB", account_number: "1000000000001",
          bank_slug: "cbe", idempotency_key: "large-payout"
        )

        assert_includes transport.requests.sole.fetch(:body), '"amount":90071992547409.93'
      end

      test "does not advertise bulk payout while returning scalar results" do
        assert_nil build_client.capabilities.dig(:payouts, :bulk)
      end

      test "reports actionable errors for invalid V2 payout configuration" do
        missing_secret = assert_raises(ArgumentError) do
          ChapaPayoutClient.new(secret_key: "", mode: "test")
        end
        assert_equal "Chapa secret key is required", missing_secret.message

        wrong_prefix = assert_raises(ArgumentError) do
          ChapaPayoutClient.new(secret_key: "CHAPA_LIVE_secret", mode: "test")
        end
        assert_equal "Chapa test secret key must start with CHAPA_TEST_", wrong_prefix.message
      end

      test "verifies a V2 payout by Chapa reference" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success",
            data: { chapa_reference: "PAYOUT-V2-2", status: "success" }
          })
        )

        result = build_client(transport:).verify_payout(provider_reference: "PAYOUT-V2-2")

        assert_predicate result, :success?
        assert_equal "/v2/payouts/PAYOUT-V2-2/verify", transport.requests.sole.fetch(:path)
      end

      test "keeps a blocked payout recoverable for reconciliation" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success",
            data: { chapa_reference: "PAYOUT-V2-BLOCKED", status: "blocked", reason: "COMPLIANCE_REVIEW" }
          })
        )

        result = build_client(transport:).payout(
          amount_minor: 100, currency: "ETB", account_number: "1000000000001",
          bank_slug: "cbe", idempotency_key: "seller-payout-v2-blocked"
        )

        assert_predicate result, :unknown?
        assert_equal "blocked", result.raw_status
        assert_equal "compliance_review", result.failure_code
      end

      test "retrieves V2 payout banks with country and normalizes slugs" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success",
            data: { items: [ { bank_slug: "cbe", bank_name: "Commercial Bank of Ethiopia" } ] }
          })
        )

        banks = build_client(transport:).available_banks(country: "ET")

        assert_equal [ { bank_slug: "cbe", bank_name: "Commercial Bank of Ethiopia" } ], banks
        assert_equal "/v2/payouts/banks?country=ET", transport.requests.sole.fetch(:path)
      end

      test "hides inactive V2 payout banks" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success",
            data: {
              items: [
                { bank_slug: "cbe", bank_name: "Commercial Bank of Ethiopia", is_active: true },
                { bank_slug: "closed-bank", bank_name: "Closed Bank", is_active: false }
              ]
            }
          })
        )

        banks = build_client(transport:).available_banks(country: "ET")

        assert_equal [
          { bank_slug: "cbe", bank_name: "Commercial Bank of Ethiopia", is_active: true }
        ], banks
      end

      private

      def build_client(transport: nil)
        ChapaPayoutClient.new(
          secret_key: "CHAPA_TEST_secret",
          mode: "test",
          api_base_url: "https://api.chapa.test",
          transport:
        )
      end
    end
  end
end
