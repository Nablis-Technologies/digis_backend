# frozen_string_literal: true

require "test_helper"

module Orders
  class ConcurrentPaymentSuccessTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include Finance::LedgerTestHelpers

    class WebhookAdapter < Payments::Providers::Adapter
      def verify_webhook(**) = true

      def create(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def cancel(**) = Payments::Providers::Result.cancelled(raw_status: "cancelled")

      def verify(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def refund(**) = Payments::Providers::Result.success(provider_reference: "refund-ref")

      def verify_refund(**) = Payments::Providers::Result.success(provider_reference: "refund-ref")

      def available_balance(**) = { amount_minor: 100_000, currency: "ETB" }

      def capabilities = {}

      def settlement_grace_minutes = 5
    end

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      Payments::Providers::Registry.register("chapa", WebhookAdapter.new)
      Orders::Order.where(event: @event, buyer_user: @buyer).where(status: %w[draft pending_payment]).update_all(
        status: "cancelled", closed_reason: "test_cleanup"
      )
      @order = Orders::Order.create!(order_attributes)
      @payments = 2.times.map do |index|
        Orders::Payment.create!(payment_attributes(
          attempt_number: index + 1,
          provider_reference: "ref-#{index}-#{SecureRandom.hex(4)}",
          status: index.zero? ? "succeeded" : "processing"
        ))
      end
      @payments.first.update_columns(superseded_at: Time.current)
      @events = @payments.map.with_index do |payment, index|
        Orders::RecordPaymentEvent.call(
          provider: "chapa",
          provider_event_id: "concurrent-#{index}",
          event_type: "payment.succeeded",
          payload: { "status" => "paid", "provider_reference" => payment.provider_reference },
          raw_payload: JSON.generate(status: "paid", provider_reference: payment.provider_reference),
          signature: "valid-signature",
          headers: {}
        ).value
      end
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
      refund_ids = Orders::Refund.where(payment_id: @payments.map(&:id)).pluck(:id)
      Orders::Refund.where(id: refund_ids).delete_all
      Orders::PaymentEvent.where(id: @events.map(&:id)).delete_all
      cleanup_payment_ledger_entries(payment_ids: @payments.map(&:id))
      Orders::Payment.where(id: @payments.map(&:id)).delete_all
      Core::OutboxEvent.where(aggregate_type: "Orders::Order", aggregate_id: @order.id).delete_all
      @order.update_columns(status: "draft", paid_at: nil, closed_reason: nil)
      Orders::Order.where(id: @order.id).delete_all
    end

    test "accepts only one concurrent success and reverses the loser" do
      race = run_database_race(worker_count: @events.length) do |index|
        Orders::ProcessPaymentEvent.call(event_id: @events.fetch(index).id)
      end
      results = race.results

      assert_empty race.errors, race.errors.inspect
      assert results.all?(&:success?), results.map { |result| [ result.error&.code, result.error&.message ] }.inspect
      assert_equal 1, Orders::Payment.where(id: @payments.map(&:id)).where.not(accepted_at: nil).count
      assert_equal 1, Orders::Refund.where(payment_id: @payments.map(&:id), type: "payment_reversal").count
      assert_equal "fulfilled", @order.reload.status
      assert_equal 1, Core::OutboxEvent.where(
        aggregate_type: "Orders::Order", aggregate_id: @order.id,
        event_type: "orders.payment.fulfilled"
      ).count
    end

    private

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

    def payment_attributes(attempt_number:, provider_reference:, status:)
      {
        order: @order,
        attempt_number:,
        provider: "chapa",
        payment_method: "telebirr",
        status:,
        amount_minor: @order.total_minor,
        currency: @order.charge_currency,
        commercial_signature: @order.commercial_signature,
        buyer_fee_minor: 500,
        organizer_fee_minor: 0,
        idempotency_key: "payment-#{attempt_number}-#{SecureRandom.hex(6)}",
        provider_reference:,
        superseded_at: nil,
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @order.expires_at + 5.minutes
      }
    end
  end
end
