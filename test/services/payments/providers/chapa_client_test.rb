# frozen_string_literal: true

require "openssl"
require "test_helper"

module Payments
  module Providers
    class ChapaClientTest < ActiveSupport::TestCase
      Response = Data.define(:status, :body)

      class FakeTransport
        attr_reader :requests

        def initialize(*responses)
          @responses = responses
          @requests = []
        end

        def call(method:, path:, headers:, body:)
          @requests << { method:, path:, headers:, body: }
          @responses.shift || Response.new(status: 200, body: {})
        end
      end

      test "initializes an ETB payment with a hosted checkout URL" do
        transport = FakeTransport.new(
          Response.new(
            status: 200,
            body: {
              status: "success",
              data: {
                status: "pending",
                tx_ref: "attempt-1",
                checkout_url: "https://checkout.chapa.test/attempt-1"
              }
            }
          )
        )

        result = build_client(transport:).create(
          amount_minor: 1_250,
          currency: "ETB",
          idempotency_key: "attempt-1",
          email: "buyer@example.com",
          phone_number: "+251911000000"
        )

        assert_predicate result, :unknown?
        assert_equal "attempt-1", result.provider_reference
        assert_equal "https://checkout.chapa.test/attempt-1", result.checkout_url
        request = transport.requests.sole
        assert_equal :post, request.fetch(:method)
        assert_equal "/transaction/initialize", request.fetch(:path)
        assert_equal "Bearer CHASECK_TEST-secret", request.dig(:headers, "Authorization")
        payload = JSON.parse(request.fetch(:body))
        assert_equal "12.50", payload.fetch("amount")
        assert_equal "attempt-1", payload.fetch("tx_ref")
        assert_equal "buyer@example.com", payload.fetch("email")
        assert_equal "0911000000", payload.fetch("phone_number")
      end

      test "keeps hosted checkout initialization pending until payment confirmation" do
        transport = FakeTransport.new(
          Response.new(
            status: 200,
            body: {
              status: "success",
              data: {
                checkout_url: "https://checkout.chapa.test/attempt-pending"
              }
            }
          )
        )

        result = build_client(transport:).create(
          amount_minor: 1_000,
          currency: "ETB",
          idempotency_key: "attempt-pending",
          email: "buyer@example.com",
          phone_number: "+251911000000"
        )

        assert_predicate result, :unknown?
        assert_equal "initialized", result.raw_status
        assert_equal "https://checkout.chapa.test/attempt-pending", result.checkout_url
      end

      test "verifies a payment and normalizes the provider fee" do
        transport = FakeTransport.new(
          Response.new(
            status: 200,
            body: {
              status: "success",
              data: {
                status: "success",
                tx_ref: "attempt-1",
                charge: "1.25",
                currency: "ETB"
              }
            }
          )
        )

        result = build_client(transport:).verify(provider_reference: "attempt-1")

        assert_predicate result, :success?
        assert_equal "attempt-1", result.provider_reference
        assert_equal 125, result.provider_fee_minor
        assert_equal "ETB", result.provider_fee_currency
        assert_equal "/transaction/verify/attempt-1", transport.requests.sole.fetch(:path)
      end

      test "logs safe metadata for a rejected transaction" do
        transport = FakeTransport.new(
          Response.new(
            status: 404,
            body: {
              status: "failed",
              message: "Payments through API is disabled, please contact us",
              data: nil
            }
          )
        )
        Rails.logger.expects(:warn).with(
          includes("status_code=404", "status=failed", "Payments through API is disabled")
        )

        result = build_client(transport:).create(
          amount_minor: 1_000,
          currency: "ETB",
          idempotency_key: "attempt-rejected",
          email: "buyer@example.com",
          phone_number: "+251911000000"
        )

        assert_predicate result, :failure?
      end

      test "verifies Chapa webhook signatures against the exact raw body" do
        raw_body = '{"event":"charge.success","tx_ref":"attempt-1"}'
        signature = OpenSSL::HMAC.hexdigest("SHA256", "webhook-secret", raw_body)
        client = build_client(webhook_secret: "webhook-secret")

        assert client.verify_webhook(payload: raw_body, headers: { "x-chapa-signature" => signature })
        assert_not client.verify_webhook(payload: raw_body, headers: { "x-chapa-signature" => "invalid" })
        assert_not client.verify_webhook(payload: raw_body, headers: {})
      end

      test "requires a mode-matching Chapa secret key" do
        assert_raises(ArgumentError) do
          ChapaClient.new(secret_key: "CHASECK-live", webhook_secret: "secret", mode: "test")
        end

        assert_raises(ArgumentError) do
          ChapaClient.new(secret_key: "CHASECK_TEST-secret", webhook_secret: "secret", mode: "live")
        end
      end

      test "maps refund verification and available balance without exposing provider payloads" do
        transport = FakeTransport.new(
          Response.new(
            status: 200,
            body: {
              status: "success",
              data: { status: "refunded", ref_id: "refund-1", currency: "ETB" }
            }
          ),
          Response.new(
            status: 200,
            body: {
              status: "success",
              data: [ { currency: "ETB", available_balance: "42.50" } ]
            }
          )
        )

        client = build_client(transport:)
        refund = client.verify_refund(provider_reference: "refund-1")
        balance = client.available_balance(currency: "ETB")

        assert_predicate refund, :success?
        assert_equal "refund-1", refund.provider_reference
        assert_equal({ amount_minor: 4_250, currency: "ETB" }, balance)
        refute_match(/secret|payload|CHASECK/i, refund.raw_status.to_s)
      end

      private

      def build_client(transport: nil, webhook_secret: "webhook-secret")
        ChapaClient.new(
          secret_key: "CHASECK_TEST-secret",
          webhook_secret:,
          api_base_url: "https://api.chapa.test/v1",
          callback_url: "https://digis.example/payments/chapa/webhook",
          return_url: "https://digis.example/payments/return",
          transport:
        )
      end
    end
  end
end
