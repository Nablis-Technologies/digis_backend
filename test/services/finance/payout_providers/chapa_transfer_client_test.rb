# frozen_string_literal: true

require "json"
require "test_helper"

module Finance
  module PayoutProviders
    class ChapaTransferClientTest < ActiveSupport::TestCase
      Response = Data.define(:status, :body)

      class FakeTransport
        attr_reader :requests

        def initialize(*responses)
          @responses = responses
          @requests = []
        end

        def call(method:, path:, headers:, body: nil)
          @requests << { method:, path:, headers:, body: }
          response = @responses.shift
          raise response if response.is_a?(Exception)

          response || Response.new(status: 200, body: {})
        end
      end

      test "initializes a transfer with Chapa's bank-transfer payload" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success",
            data: { reference: "transfer-1", status: "success" }
          })
        )

        result = build_client(transport:).payout(
          amount_minor: 1_250,
          currency: "ETB",
          account_number: "1000000000001",
          account_name: "Organizer Account",
          bank_code: 128,
          idempotency_key: "payout-1"
        )

        assert_predicate result, :success?
        assert_equal "transfer-1", result.provider_reference

        request = transport.requests.sole
        assert_equal :post, request.fetch(:method)
        assert_equal "/transfers", request.fetch(:path)
        assert_equal "Bearer CHASECK_TEST-secret", request.dig(:headers, "Authorization")
        payload = JSON.parse(request.fetch(:body))
        assert_equal(
          {
            "account_number" => "1000000000001",
            "account_name" => "Organizer Account",
            "amount" => "12.50",
            "bank_code" => 128,
            "currency" => "ETB",
            "reference" => "payout-1"
          },
          payload
        )
      end

      test "omits optional account name when absent" do
        transport = FakeTransport.new(Response.new(status: 200, body: { status: "success", data: {} }))

        build_client(transport:).payout(
          amount_minor: 100,
          currency: "ETB",
          account_number: "1000000000001",
          bank_code: 128,
          idempotency_key: "payout-without-name"
        )

        payload = JSON.parse(transport.requests.sole.fetch(:body))
        refute payload.key?("account_name")
      end

      test "verifies a transfer by its payout reference" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success",
            data: { status: "pending", reference: "transfer-2" }
          })
        )

        result = build_client(transport:).verify_payout(provider_reference: "transfer-2")

        assert_predicate result, :unknown?
        assert_equal "transfer-2", result.provider_reference
        assert_equal :get, transport.requests.sole.fetch(:method)
        assert_equal "/transfers/verify/transfer-2", transport.requests.sole.fetch(:path)
      end

      test "keeps a queued transfer recoverable instead of treating it as failed" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success",
            data: { status: "pending", reference: "transfer-queued" }
          })
        )

        result = build_client(transport:).payout(
          amount_minor: 100,
          currency: "ETB",
          account_number: "1000000000001",
          bank_code: 128,
          idempotency_key: "payout-queued"
        )

        assert_predicate result, :unknown?
        assert_equal "pending", result.raw_status
        assert_equal "transfer-queued", result.provider_reference
      end

      test "maps a rejected transfer into the finance result contract" do
        transport = FakeTransport.new(
          Response.new(status: 400, body: {
            status: "failed",
            message: "Insufficient Balance",
            data: nil
          })
        )

        result = build_client(transport:).payout(
          amount_minor: 100,
          currency: "ETB",
          account_number: "1000000000001",
          bank_code: 128,
          idempotency_key: "payout-failed"
        )

        assert_predicate result, :failure?
        assert_equal "failed", result.failure_code
      end

      test "maps a provider timeout into a recoverable timeout result" do
        transport = FakeTransport.new(Net::ReadTimeout.new)

        result = build_client(transport:).payout(
          amount_minor: 100,
          currency: "ETB",
          account_number: "1000000000001",
          bank_code: 128,
          idempotency_key: "payout-timeout"
        )

        assert_predicate result, :timeout?
      end

      test "rejects a transfer without a beneficiary account" do
        assert_raises(ArgumentError) do
          build_client.payout(
            amount_minor: 100,
            currency: "ETB",
            bank_code: 128,
            idempotency_key: "payout-missing-account"
          )
        end
      end

      test "normalizes a blank successful response to an unknown result" do
        transport = FakeTransport.new(Response.new(status: 200, body: {}))

        result = build_client(transport:).payout(
          amount_minor: 100,
          currency: "ETB",
          account_number: "1000000000001",
          bank_code: 128,
          idempotency_key: "payout-empty-response"
        )

        assert_predicate result, :unknown?
        assert_nil result.provider_reference
      end

      test "maps the available transfer balance into minor units" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success",
            data: [ { currency: "ETB", available_balance: "42.50" } ]
          })
        )

        balance = build_client(transport:).available_balance(currency: "ETB")

        assert_equal({ amount_minor: 4_250, currency: "ETB" }, balance)
        assert_equal "/balances/etb", transport.requests.sole.fetch(:path)
      end

      test "requires a mode-matching Chapa secret key" do
        assert_raises(ArgumentError) do
          ChapaTransferClient.new(secret_key: "CHASECK-live", mode: "test")
        end

        assert_raises(ArgumentError) do
          ChapaTransferClient.new(secret_key: "CHASECK_TEST-secret", mode: "live")
        end
      end

      private

      def build_client(transport: nil)
        ChapaTransferClient.new(
          secret_key: "CHASECK_TEST-secret",
          api_base_url: "https://api.chapa.test/v1",
          transport:
        )
      end
    end
  end
end
