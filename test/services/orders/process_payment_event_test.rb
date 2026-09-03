# frozen_string_literal: true

require "test_helper"

module Orders
  class ProcessPaymentEventTest < ActiveSupport::TestCase
    class WebhookAdapter < Payments::Providers::Adapter
      attr_accessor :webhook_valid

      def initialize
        @webhook_valid = true
      end

      def verify_webhook(**) = webhook_valid

      def create(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def cancel(**) = Payments::Providers::Result.cancelled(raw_status: "cancelled")

      def verify(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def refund(**) = Payments::Providers::Result.success(provider_reference: "refund-ref")

      def verify_refund(**) = Payments::Providers::Result.success(provider_reference: "refund-ref")

      def available_balance(**) = { amount_minor: 100_000, currency: "ETB" }

      def capabilities = { currencies: [ "ETB" ], payment_methods: [ "telebirr" ] }

      def settlement_grace_minutes = 5
    end

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      Orders::Order.where(event: @event, buyer_user: @buyer).where(status: %w[draft pending_payment]).update_all(
        status: "cancelled", closed_reason: "test_cleanup"
      )
      @order = Orders::Order.create!(order_attributes)
      @payment = Orders::Payment.create!(payment_attributes)
      @adapter = WebhookAdapter.new
      Payments::Providers::Registry.register("chapa", @adapter)
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
    end

    test "accepts a verified success once and publishes one fulfillment effect" do
      event = record_event(event_id: "evt-success", event_type: "payment.succeeded")

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "processed", event.reload.status
      assert_equal "succeeded", @payment.reload.status
      assert @payment.accepted?
      assert_equal "fulfilled", @order.reload.status
      assert_equal 1, Core::OutboxEvent.where(
        aggregate_type: "Orders::Order", aggregate_id: @order.id,
        event_type: "orders.payment.fulfilled"
      ).count

      replay = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate replay, :success?, replay.error&.message
      assert_equal 1, Core::OutboxEvent.where(
        aggregate_type: "Orders::Order", aggregate_id: @order.id,
        event_type: "orders.payment.fulfilled"
      ).count
    end

    test "replays fulfillment safely when inbox processing resumes after the commit" do
      event = record_event(event_id: "evt-fulfillment-replay", event_type: "payment.succeeded")
      assert_predicate Orders::ProcessPaymentEvent.call(event:), :success?

      event.update!(status: "processing", processed_at: nil)
      replay = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate replay, :success?, replay.error&.message
      assert_equal "processed", event.reload.status
      assert_equal 1, Core::OutboxEvent.where(
        aggregate_type: "Orders::Order", aggregate_id: @order.id,
        event_type: "orders.payment.fulfilled"
      ).count
    end

    test "stores a duplicate provider event once" do
      first = record_event(event_id: "evt-duplicate", event_type: "payment.pending")
      second = record_event(event_id: "evt-duplicate", event_type: "payment.pending")

      assert_equal first.id, second.id
      assert_equal 1, Orders::PaymentEvent.where(provider: "chapa", provider_event_id: "evt-duplicate").count
    end

    test "locates a Chapa webhook payment by its transaction reference" do
      event = record_event(
        event_id: "chapa-reference-event",
        event_type: "payment.succeeded",
        payload: { "status" => "success", "tx_ref" => @payment.idempotency_key }
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "fulfilled", @order.reload.status
      assert_equal "succeeded", @payment.reload.status
    end

    test "publishes one terminal failure event when payment processing fails" do
      event = record_event(
        event_id: "evt-failure",
        event_type: "payment.failed",
        payload: {
          "status" => "failed",
          "failure_code" => "declined",
          "provider_reference" => @payment.provider_reference
        }
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      outbox = Core::OutboxEvent.find_by!(
        aggregate_type: "Orders::Payment", aggregate_id: @payment.id,
        event_type: "orders.payment.failed"
      )
      assert_equal @payment.id, outbox.payload.fetch("payment_id")
      assert_equal event.id, outbox.payload.fetch("payment_event_id")
    end

    test "rolls back inbox receipt when publishing its outbox event fails" do
      outbox_error = Core::Error.new("outbox unavailable")
      publish_failure = Core::BaseService::Result.failure(outbox_error)
      original_publish = Core::Outbox::Publish.method(:call)

      assert_raises(Core::Error) do
        Core::Outbox::Publish.define_singleton_method(:call) { |**| publish_failure }
        begin
          record_event(event_id: "evt-receipt-rollback", event_type: "payment.pending")
        ensure
          Core::Outbox::Publish.define_singleton_method(:call, original_publish)
        end
      end

      assert_not Orders::PaymentEvent.exists?(provider_event_id: "evt-receipt-rollback")
    end

    test "ignores an unknown provider event without changing the order" do
      event = record_event(event_id: "evt-unknown", event_type: "payment.refunded", payload: {
        "status" => "refunded", "provider_reference" => "unknown-ref"
      })

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "ignored", event.reload.status
      assert_equal "pending_payment", @order.reload.status
      assert_nil @payment.reload.accepted_at
    end

    test "creates one full reversal for a superseded success" do
      @payment.update_columns(superseded_at: Time.current)
      event = record_event(event_id: "evt-superseded", event_type: "payment.succeeded")

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "succeeded", @payment.reload.status
      assert_nil @payment.accepted_at
      assert_equal "pending_payment", @order.reload.status
      reversal = Orders::Refund.find_by!(payment: @payment)
      assert_equal "payment_reversal", reversal.type
      assert_equal "superseded_attempt", reversal.reason_code
      assert_equal @payment.amount_minor, reversal.amount_minor
      assert_equal 1, Orders::Refund.where(payment: @payment).count
    end

    test "reverses a success discovered after the order was finally released" do
      @order.update_columns(status: "expired", closed_reason: "checkout_expired")
      event = record_event(event_id: "evt-late", event_type: "payment.succeeded")

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "late_payment", Orders::Refund.find_by!(payment: @payment).reason_code
      assert_equal "expired", @order.reload.status
      assert_nil @payment.reload.accepted_at
    end

    test "reverses a provider success discovered after event cancellation" do
      @event.update!(status: "cancelled")
      event = record_event(event_id: "evt-cancelled-event", event_type: "payment.succeeded")

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "event_cancelled", Orders::Refund.find_by!(payment: @payment).reason_code
      assert_equal "pending_payment", @order.reload.status
      assert_nil @payment.reload.accepted_at
    end

    test "rejects an invalid webhook signature before persisting the event" do
      @adapter.webhook_valid = false

      result = record_event(event_id: "evt-invalid-signature", event_type: "payment.succeeded")

      assert_predicate result, :failure?
      assert_equal "invalid_webhook_signature", result.error.code
      assert_not Orders::PaymentEvent.exists?(provider_event_id: "evt-invalid-signature")
    end

    private

    def record_event(event_id:, event_type:, payload: nil)
      Orders::RecordPaymentEvent.call(
        provider: "chapa",
        provider_event_id: event_id,
        event_type:,
        payload: payload || { "status" => "paid", "provider_reference" => @payment.provider_reference },
        raw_payload: JSON.generate(payload || { status: "paid", provider_reference: @payment.provider_reference }),
        signature: "valid-signature",
        headers: { "X-Provider-Signature" => "valid-signature" }
      ).then { |result| result.success? ? result.value : result }
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

    def payment_attributes
      {
        order: @order,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "processing",
        amount_minor: @order.total_minor,
        currency: @order.charge_currency,
        commercial_signature: @order.commercial_signature,
        buyer_fee_minor: 500,
        organizer_fee_minor: 0,
        idempotency_key: "payment-#{SecureRandom.hex(6)}",
        provider_reference: "provider-ref-#{SecureRandom.hex(4)}",
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @order.expires_at + 5.minutes
      }
    end
  end
end
