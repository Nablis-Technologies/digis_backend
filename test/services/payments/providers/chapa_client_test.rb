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

        def call(method:, path:, headers:, body: nil)
          @requests << { method:, path:, headers:, body: }
          @responses.shift || Response.new(status: 200, body: {})
        end
      end

      test "initializes an ETB V2 hosted payment with a checkout URL" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success", data: { checkout_url: "https://checkout.chapa.test/attempt-1" }
          })
        )

        result = build_client(transport:).create(
          amount_minor: 1_200, currency: "ETB", idempotency_key: "attempt-1",
          email: "buyer@example.com", phone_number: "+251911000000"
        )

        assert_predicate result, :unknown?
        assert_equal "https://checkout.chapa.test/attempt-1", result.checkout_url
        request = transport.requests.sole
        assert_equal "/v2/payments/hosted", request.fetch(:path)
        assert_equal "Bearer CHAPA_TEST_secret", request.dig(:headers, "Authorization")
        assert_equal "attempt-1", request.dig(:headers, "Idempotency-Key")
        payload = JSON.parse(request.fetch(:body))
        assert_equal 12, payload.fetch("amount")
        assert_equal "attempt-1", payload.fetch("merchant_reference")
        assert_equal "buyer@example.com", payload.dig("customer", "email")
        assert_equal "+251911000000", payload.dig("customer", "phone_number")
      end

      test "omits absent customer fields from the V2 hosted payload" do
        transport = FakeTransport.new(Response.new(status: 200, body: { status: "success", data: {} }))

        build_client(transport:).create(amount_minor: 1_000, currency: "ETB", idempotency_key: "optional")

        assert_equal({}, JSON.parse(transport.requests.sole.fetch(:body)).fetch("customer"))
      end

      test "initializes a V2 direct charge with an authentication state" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success",
            data: { auth_type: "ussd", request_id: "request-1", chapa_reference: "CHV2-1", payment_status: "PENDING" }
          })
        )

        result = build_client(transport:).direct_charge(
          amount_minor: 100, currency: "ETB", idempotency_key: "direct-1",
          payment_method: "telebirr", phone_number: "+251911000000"
        )

        assert_predicate result, :unknown?
        assert_equal "CHV2-1", result.provider_reference
        assert_equal "ussd", result.auth_type
        assert_equal "request-1", result.request_id
        assert_equal "/v2/payments/direct", transport.requests.sole.fetch(:path)
        assert_equal "telebirr", JSON.parse(transport.requests.sole.fetch(:body)).fetch("payment_method")
      end

      test "does not parse an untrusted webhook before checking its signature" do
        original_parse = JSON.method(:parse)
        parse_called = false
        JSON.define_singleton_method(:parse) { |*| parse_called = true; {} }

        begin
          assert_not build_client.verify_webhook(
            payload: '{"malformed":', headers: { "x-chapa-signature" => "invalid" }
          )
          assert_not parse_called
        ensure
          JSON.define_singleton_method(:parse, original_parse)
        end
      end

      test "serializes large minor amounts without floating point loss" do
        transport = FakeTransport.new(Response.new(status: 200, body: { status: "success", data: {} }))

        build_client(transport:).create(
          amount_minor: 900_719_925_474_099_300, currency: "ETB", idempotency_key: "large-amount"
        )

        assert_includes transport.requests.sole.fetch(:body), '"amount":9007199254740993'
      end

      test "uses the shared Core transport by default" do
        transport = build_client.instance_variable_get(:@transport)

        assert_instance_of Core::HttpTransport, transport
      end

      test "maps a blocked V2 payment to a retryable unknown state" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success", data: { status: "blocked", chapa_reference: "CHV2-blocked" }
          })
        )

        result = build_client(transport:).verify(provider_reference: "CHV2-blocked")

        assert_predicate result, :unknown?
        assert_equal "blocked", result.failure_code
      end

      test "rejects a zero minor-unit payment amount" do
        assert_raises(ArgumentError) do
          build_client.create(amount_minor: 0, currency: "ETB", idempotency_key: "zero-amount")
        end
      end

      test "rejects a fractional ETB amount before provider I/O" do
        transport = FakeTransport.new

        result = build_client(transport:).create(
          amount_minor: 513, currency: "ETB", idempotency_key: "fractional-amount"
        )

        assert_predicate result, :failure?
        assert_equal "amount_precision_unsupported", result.failure_code
        assert_empty transport.requests
      end

      test "verifies a V2 payment and normalizes the provider fee" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success",
            data: { status: "success", chapa_reference: "CHV2-verified", service_fee: "1.25", currency: "ETB" }
          })
        )

        result = build_client(transport:).verify(provider_reference: "CHV2-verified")

        assert_predicate result, :success?
        assert_equal "CHV2-verified", result.provider_reference
        assert_equal 125, result.provider_fee_minor
        assert_equal "/v2/payments/CHV2-verified/verify", transport.requests.sole.fetch(:path)
      end

      test "verifies V2 webhook signatures against exact raw bytes and normalized Rack headers" do
        raw_body = '{"event":"payment.success","mode":"test","merchant_reference":"attempt-1"}'
        signature = OpenSSL::HMAC.hexdigest("SHA256", "webhook-secret", raw_body)
        client = build_client(webhook_secret: "webhook-secret")

        assert client.verify_webhook(payload: raw_body, headers: { "HTTP_X_CHAPA_SIGNATURE" => signature })
        assert_not client.verify_webhook(payload: raw_body, headers: { "x-chapa-signature" => "invalid" })
      end

      test "rejects a correctly signed webhook from the wrong environment" do
        raw_body = '{"event":"payment.success","mode":"live","merchant_reference":"attempt-live"}'
        signature = OpenSSL::HMAC.hexdigest("SHA256", "webhook-secret", raw_body)

        assert_not build_client.verify_webhook(
          payload: raw_body, headers: { "x-chapa-signature" => signature }
        )
      end

      test "maps V2 refund verification and leaves undocumented balance preflight unavailable" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success", data: { status: "completed", chapa_reference: "RFND-1", currency: "ETB" }
          })
        )
        client = build_client(transport:)

        refund = client.verify_refund(provider_reference: "RFND-1")

        assert_predicate refund, :success?
        assert_equal "RFND-1", refund.provider_reference
        assert_nil client.available_balance(currency: "ETB")
      end

      test "submits a V2 partial refund with a native idempotency key" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success", data: { status: "pending", chapa_reference: "RFND-2" }
          })
        )

        result = build_client(transport:).refund(
          provider_reference: "CHV2-payment-1", amount_minor: 100,
          currency: "ETB", idempotency_key: "refund-2", refund_type: "item_refund"
        )

        assert_predicate result, :unknown?
        request = transport.requests.sole
        assert_equal "/v2/refunds", request.fetch(:path)
        assert_equal "refund-2", request.dig(:headers, "Idempotency-Key")
        payload = JSON.parse(request.fetch(:body))
        assert_equal "CHV2-payment-1", payload.fetch("payment_reference")
        assert_equal 1.0, payload.fetch("amount")
      end

      test "requires a V2 mode-matching secret key" do
        assert_raises(ArgumentError) do
          ChapaClient.new(secret_key: "LEGACY_TEST_secret", webhook_secret: "secret", mode: "test")
        end

        assert_raises(ArgumentError) do
          ChapaClient.new(secret_key: "CHAPA_LIVE_secret", webhook_secret: "secret", mode: "test")
        end
      end

      private

      def build_client(transport: nil, webhook_secret: "webhook-secret")
        ChapaClient.new(
          secret_key: "CHAPA_TEST_secret", webhook_secret:, mode: "test",
          api_base_url: "https://api.chapa.test", transport:
        )
      end
    end
  end
end
