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
          merchant_reference: "attempt-1",
          email: "buyer@example.com", phone_number: "+251911000000"
        )

        assert_predicate result, :unknown?
        assert_equal "https://checkout.chapa.test/attempt-1", result.checkout_url
        request = transport.requests.sole
        assert_equal "/v2/payments/hosted", request.fetch(:path)
        assert_equal "Bearer CHAPA_TEST_secret", request.dig(:headers, "Authorization")
        assert_equal "attempt-1", request.dig(:headers, "Idempotency-Key")
        payload = JSON.parse(request.fetch(:body))
        assert_equal 1_200, payload.fetch("amount")
        assert_equal "attempt-1", payload.fetch("merchant_reference")
        assert_equal "buyer@example.com", payload.dig("customer", "email")
        assert_equal "+251911000000", payload.dig("customer", "phone_number")
      end

      test "separates a long client idempotency key from Chapa merchant_reference" do
        client_key = "DIGIS_DIAG_20260913182310"
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success", data: { checkout_url: "https://checkout.chapa.test/bounded" }
          })
        )

        result = build_client(transport:).create(
          amount_minor: 4_100, currency: "ETB", idempotency_key: client_key,
          payment_id: "payment-1", order_id: "order-1", attempt_number: 1
        )

        assert_predicate result, :unknown?
        request = transport.requests.sole
        payload = JSON.parse(request.fetch(:body))
        merchant_reference = payload.fetch("merchant_reference")
        assert_equal 20, merchant_reference.length
        assert_match(/\A[0-9a-f]{20}\z/, merchant_reference)
        assert_equal client_key, request.dig(:headers, "Idempotency-Key")
        refute_equal client_key, merchant_reference
      end

      test "omits absent customer fields from the V2 hosted payload" do
        transport = FakeTransport.new(Response.new(status: 200, body: { status: "success", data: {} }))

        build_client(transport:).create(amount_minor: 1_000, currency: "ETB", idempotency_key: "optional")

        assert_equal({}, JSON.parse(transport.requests.sole.fetch(:body)).fetch("customer"))
      end

      test "does not send the internal payment method as an undocumented hosted preference" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success", data: { checkout_url: "https://checkout.chapa.test/attempt-2" }
          })
        )

        build_client(transport:).create(
          amount_minor: 1_200, currency: "ETB", idempotency_key: "attempt-2", payment_method: "telebirr"
        )

        payload = JSON.parse(transport.requests.sole.fetch(:body))
        assert_not payload.key?("preferred_payment_methods")
      end

      test "includes configured callback and return URLs in the hosted payload" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success", data: { checkout_url: "https://checkout.chapa.test/redirected" }
          })
        )

        build_client(
          transport:,
          callback_url: "https://digis.example/payments/chapa/callback",
          return_url: "https://digis.example/payments/chapa/callback"
        ).create(amount_minor: 4_100, currency: "ETB", idempotency_key: "redirected")

        payload = JSON.parse(transport.requests.sole.fetch(:body))
        assert_equal "https://digis.example/payments/chapa/callback", payload.fetch("callback_url")
        assert_equal "https://digis.example/payments/chapa/callback", payload.fetch("return_url")
      end

      test "does not send hosted redirect URLs to direct charge" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success", data: { chapa_reference: "CHV2-direct-redirect" }
          })
        )

        build_client(
          transport:,
          callback_url: "https://digis.example/payments/chapa/callback",
          return_url: "https://digis.example/payments/chapa/callback"
        ).direct_charge(
          amount_minor: 4_100, currency: "ETB", idempotency_key: "direct-redirect",
          payment_method: "telebirr", phone_number: "+251900000000"
        )

        payload = JSON.parse(transport.requests.sole.fetch(:body))
        assert_not payload.key?("callback_url")
        assert_not payload.key?("return_url")
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

      test "returns a typed failure for the deferred hosted cancellation operation" do
        result = build_client.cancel(payment_id: "payment-1", idempotency_key: "cancel-1")

        assert_predicate result, :failure?
        assert_equal "cancellation_unsupported", result.failure_code
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

        assert_includes transport.requests.sole.fetch(:body), '"amount":900719925474099300'
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

      test "sends fractional ETB amounts as integer minor units" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: {
            status: "success", data: { checkout_url: "https://checkout.chapa.test/fractional" }
          })
        )

        result = build_client(transport:).create(
          amount_minor: 513, currency: "ETB", idempotency_key: "fractional-amount"
        )

        assert_predicate result, :unknown?
        assert_equal 513, JSON.parse(transport.requests.sole.fetch(:body)).fetch("amount")
      end

      test "fails a hosted initialization that does not return a checkout URL" do
        transport = FakeTransport.new(
          Response.new(status: 200, body: { status: "success", data: { status: "processing" } })
        )

        result = build_client(transport:).create(
          amount_minor: 1_200, currency: "ETB", idempotency_key: "missing-checkout-url"
        )

        assert_predicate result, :failure?
        assert_equal "checkout_url_missing", result.failure_code
      end

      test "maps a Chapa HTTP rejection into a typed provider failure" do
        transport = FakeTransport.new(
          Response.new(status: 400, body: {
            status: "error", message: "Invalid amount", error: { code: "invalid_format" }
          })
        )

        result = build_client(transport:).create(
          amount_minor: 513, currency: "ETB", idempotency_key: "provider-rejection"
        )

        assert_predicate result, :failure?
        assert_equal "invalid_format", result.failure_code
        assert_equal "provider_rejected", result.raw_status
      end

      test "preserves a provider processing failure and request ID for HTTP 500" do
        transport = FakeTransport.new(
          Response.new(status: 500, body: {
            status: "error",
            message: "Internal server error",
            error: { code: "PROCESSING_FAILED", details: { request_id: "REQ-500" } }
          })
        )

        result = build_client(transport:).create(
          amount_minor: 4_100, currency: "ETB", idempotency_key: "provider-500"
        )

        assert_predicate result, :unknown?
        assert_equal "processing_failed", result.failure_code
        assert_equal "provider_unavailable", result.raw_status
        assert_equal "REQ-500", result.request_id
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

      test "verifies a signature explicitly supplied by the webhook controller" do
        raw_body = '{"event":"payment.success","mode":"test","merchant_reference":"attempt-2"}'
        signature = OpenSSL::HMAC.hexdigest("SHA256", "webhook-secret", raw_body)
        client = build_client(webhook_secret: "webhook-secret")

        assert client.verify_webhook(payload: raw_body, signature:, headers: {})
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
        assert_equal 100, payload.fetch("amount")
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

      def build_client(transport: nil, webhook_secret: "webhook-secret", callback_url: nil, return_url: nil)
        ChapaClient.new(
          secret_key: "CHAPA_TEST_secret", webhook_secret:, mode: "test",
          api_base_url: "https://api.chapa.test", callback_url:, return_url:, transport:
        )
      end
    end
  end
end
