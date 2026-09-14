# frozen_string_literal: true

require "test_helper"

module Orders
  class PaymentWebhooksControllerTest < ActionDispatch::IntegrationTest
    class WebhookAdapter < Payments::Providers::Adapter
      attr_accessor :webhook_valid
      attr_reader :last_webhook_request

      def initialize
        @webhook_valid = true
      end

      def verify_webhook(**request)
        @last_webhook_request = request
        webhook_valid
      end

      def create(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def cancel(**) = Payments::Providers::Result.cancelled(raw_status: "cancelled")

      def verify(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def refund(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def verify_refund(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def available_balance(**) = { amount_minor: 100_000, currency: "ETB" }

      def capabilities = {}

      def settlement_grace_minutes = 5
    end

    setup do
      @adapter = WebhookAdapter.new
      Payments::Providers::Registry.register("chapa", @adapter)
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
    end

    test "durably acknowledges a verified webhook without authentication" do
      payload = { event_id: "evt-controller", type: "payment.succeeded", status: "paid" }

      post "/payments/chapa/webhook",
           params: payload,
           headers: { "X-Provider-Signature" => "valid-signature" },
           as: :json

      assert_response :accepted
      assert_equal true, response.parsed_body.fetch("success")
      assert_equal "evt-controller", response.parsed_body.dig("data", "provider_event_id")
      assert Orders::PaymentEvent.exists?(provider: "chapa", provider_event_id: "evt-controller")
      assert Core::OutboxEvent.exists?(event_type: "orders.payment_event.received")
    end

    test "rejects an invalid signature without persisting or publishing" do
      @adapter.webhook_valid = false

      post "/payments/chapa/webhook",
           params: { event_id: "evt-rejected", type: "payment.succeeded", status: "paid" },
           headers: { "X-Provider-Signature" => "invalid" },
           as: :json

      assert_response :unauthorized
      assert_equal "invalid_webhook_signature", response.parsed_body.fetch("code")
      assert_not Orders::PaymentEvent.exists?(provider_event_id: "evt-rejected")
      assert_not Core::OutboxEvent.exists?(event_type: "orders.payment_event.received")
    end

    test "accepts Chapa's transaction webhook field names" do
      payload = {
        event: "charge.success",
        type: "API",
        reference: "AP-chapa-reference",
        tx_ref: "chapa-transaction-reference",
        status: "success"
      }

      post "/payments/chapa/webhook",
           params: payload,
           headers: { "X-Chapa-Signature" => "valid-signature" },
           as: :json

      assert_response :accepted
      assert_equal "AP-chapa-reference", response.parsed_body.dig("data", "provider_event_id")
      assert Orders::PaymentEvent.exists?(provider_event_id: "AP-chapa-reference")
    end

    test "passes Chapa's signature header to the provider adapter" do
      payload = { event_id: "evt-explicit-signature", type: "payment.success", status: "success" }

      post "/payments/chapa/webhook",
           params: payload,
           headers: { "X-Chapa-Signature" => "header-signature" },
           as: :json

      assert_response :accepted
      assert_equal "header-signature", @adapter.last_webhook_request.fetch(:signature)
    end
  end
end
