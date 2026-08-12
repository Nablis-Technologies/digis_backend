# frozen_string_literal: true

require "test_helper"

module Orders
  class PaymentAttemptsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    class FakeAdapter < Payments::Providers::Adapter
      attr_reader :create_calls

      def initialize
        @create_calls = []
      end

      def create(**arguments)
        @create_calls << arguments
        Payments::Providers::Result.unknown(raw_status: "pending")
      end

      def cancel(**) = Payments::Providers::Result.cancelled(raw_status: "cancelled")

      def verify(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def refund(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def verify_refund(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def available_balance(**) = { amount_minor: 100_000, currency: "ETB" }

      def capabilities = { currencies: [ "ETB" ], payment_methods: [ "telebirr" ] }

      def settlement_grace_minutes = 5
    end

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @order = Orders::Order.create!(order_attributes.merge(status: "draft"))
      Orders::OrderAdjustment.create!(buyer_fee_adjustment_attributes)
      @order.update!(status: "pending_payment")
      @adapter = FakeAdapter.new
      Payments::Providers::Registry.register("chapa", @adapter)
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
      Orders::Payment.where(order_id: @order.id).delete_all if @order&.persisted?
      @order.update_columns(status: "draft", paid_at: nil, closed_reason: nil) if @order&.persisted?
      Orders::OrderAdjustment.where(order_id: @order.id).delete_all if @order&.persisted?
      Orders::Order.where(id: @order.id).delete_all if @order&.persisted?
    end

    test "starts a payment attempt and returns buyer-safe attempt data" do
      post payment_attempts_path,
           params: { payment_attempt: { provider: "chapa", payment_method: "telebirr" } },
           headers: user_headers.merge("Idempotency-Key" => "controller-attempt"), as: :json

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal "processing", data.fetch("status")
      assert_equal @order.id, data.fetch("order_id")
      assert_equal "ETB", data.fetch("currency")
      assert_not data.key?("commercial_signature")
      assert_not data.key?("idempotency_key")
    end

    test "requires an Idempotency-Key header" do
      post payment_attempts_path,
           params: { payment_attempt: { provider: "chapa", payment_method: "telebirr" } },
           headers: user_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
      assert_empty Orders::Payment.where(order: @order)
    end

    test "only the order buyer can start a payment attempt" do
      post payment_attempts_path,
           params: { payment_attempt: { provider: "chapa", payment_method: "telebirr" } },
           headers: admin_headers.merge("Idempotency-Key" => "admin-attempt"), as: :json

      assert_response :forbidden
      assert_empty Orders::Payment.where(order: @order)
    end

    test "replays the same request without creating another provider attempt" do
      request = lambda do
        post payment_attempts_path,
             params: { payment_attempt: { provider: "chapa", payment_method: "telebirr" } },
             headers: user_headers.merge("Idempotency-Key" => "controller-replay"), as: :json
      end
      run = -> do
        request.call
        assert_response :created
        first_id = response.parsed_body.dig("data", "id")
        request.call
        assert_response :created
        assert_equal first_id, response.parsed_body.dig("data", "id")
      end

      defined?(Prosopite) ? Prosopite.pause(&run) : run.call
      assert_equal 1, @adapter.create_calls.length
      assert_equal 1, Orders::Payment.where(order: @order).count
    end

    private

    def payment_attempts_path
      "/orders/#{@order.id}/payment_attempts"
    end

    def order_attributes
      {
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "pending_payment",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 10_000,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 500,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 10_500,
        settlement_currency: "ETB",
        settlement_total_minor: 10_500,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      }
    end

    def buyer_fee_adjustment_attributes
      {
        order: @order,
        type: "service_fee",
        label: "Buyer service fee",
        charged_to: "buyer",
        amount_minor: 500,
        currency: "ETB",
        refund_policy: "nonrefundable",
        calculation_type: "explicit_zero",
        funded_by: "buyer",
        source_type: "Commercial::FeeComponent",
        source_id: SecureRandom.uuid
      }
    end
  end
end
