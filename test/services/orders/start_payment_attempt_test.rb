# frozen_string_literal: true

require "test_helper"

module Orders
  class StartPaymentAttemptTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    class FakeAdapter < Payments::Providers::Adapter
      attr_accessor :result, :raise_on_create, :capabilities
      attr_reader :create_calls, :cancel_calls, :payment_present_at_create

      def initialize(result: Payments::Providers::Result.unknown(raw_status: "pending"),
        capabilities: {}, settlement_grace_minutes: 5)
        @result = result
        @capabilities = capabilities
        @settlement_grace_minutes = settlement_grace_minutes
        @create_calls = []
        @cancel_calls = []
        @payment_present_at_create = []
        @mutex = Mutex.new
      end

      def create(**arguments)
        @mutex.synchronize do
          @create_calls << arguments
          @payment_present_at_create << Orders::Payment.exists?(id: arguments.fetch(:payment_id))
        end
        raise @raise_on_create if @raise_on_create

        result
      end

      def cancel(**arguments)
        @mutex.synchronize { @cancel_calls << arguments }
        Payments::Providers::Result.cancelled(raw_status: "cancelled")
      end

      def verify(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def refund(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def verify_refund(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def merchant_reference(subject_id:, idempotency_key:, attempt_number:)
        "fake-ref-#{attempt_number}"
      end

      def available_balance(**) = { amount_minor: 100_000, currency: "ETB" }

      def capabilities = @capabilities

      def settlement_grace_minutes = @settlement_grace_minutes
    end

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @now = Time.current.change(usec: 0)
      @order = Orders::Order.create!(order_attributes.merge(status: "draft"))
      Orders::OrderAdjustment.create!(buyer_fee_adjustment_attributes)
      @order.update!(status: "pending_payment")
      @chapa = FakeAdapter.new(
        capabilities: { currencies: [ "ETB" ], payment_methods: [ "telebirr", "card", "cbebirr" ] }
      )
      @stripe = FakeAdapter.new(
        capabilities: { currencies: [ "ETB" ], payment_methods: [ "card" ] }
      )
      Payments::Providers::Registry.register("chapa", @chapa)
      Payments::Providers::Registry.register("stripe", @stripe)
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
      next unless @order&.persisted?

      Orders::Payment.where(order_id: @order.id).delete_all
      @order.update_columns(status: "draft", paid_at: nil, closed_reason: nil)
      Orders::OrderAdjustment.where(order_id: @order.id).delete_all
      Orders::Order.where(id: @order.id).delete_all
    end

    test "persists an attempt before provider creation and keeps an ambiguous result processing" do
      @chapa.result = Payments::Providers::Result.timeout(raw_status: "gateway_timeout")

      result = start(provider: "chapa", payment_method: "telebirr", key: "attempt-timeout")

      assert_predicate result, :success?, result.error&.message
      payment = result.value
      assert_equal "processing", payment.status
      assert_equal 1, payment.attempt_number
      assert_equal @order.commercial_signature, payment.commercial_signature
      assert_equal @order.expires_at + 5.minutes, payment.settlement_grace_expires_at
      assert_equal "fake-ref-1", payment.provider_merchant_reference
      assert_equal "fake-ref-1", @chapa.create_calls.sole.fetch(:merchant_reference)
      assert_equal [ true ], @chapa.payment_present_at_create
      assert_equal 1, Orders::Payment.current.where(order: @order).count
    end

    test "acquires checkout advisory before order, event, and payment locks" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        statements << payload[:sql]
      end

      result = start(provider: "chapa", payment_method: "telebirr", key: "attempt-lock-order")

      assert_predicate result, :success?, result.error&.message
      advisory_indexes = statements.each_index.select { |index| statements[index].include?("pg_advisory_xact_lock") }
      order_lock_indexes = statements.each_index.select do |index|
        statements[index].match?(/FROM\s+"orders_orders".*FOR UPDATE/i)
      end
      event_lock_index = statements.index { |sql| sql.match?(/FROM\s+"events_events".*FOR UPDATE/i) }
      payment_lock_indexes = statements.each_index.select do |index|
        statements[index].match?(/FROM\s+"orders_payments".*FOR UPDATE/i)
      end

      assert_operator advisory_indexes.length, :>=, 2, "expected locks for attempt reservation and provider-result persistence"
      assert_not_nil order_lock_indexes.first, "expected an order row lock"
      assert_not_nil event_lock_index, "expected an event row lock"
      assert_not_nil payment_lock_indexes.last, "expected the final payment row lock"
      assert_operator advisory_indexes.first, :<, order_lock_indexes.first
      assert_operator order_lock_indexes.first, :<, event_lock_index
      assert_operator event_lock_index, :<, payment_lock_indexes.first
      assert_operator advisory_indexes.last, :<, payment_lock_indexes.last
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    test "persists the buyer-safe hosted checkout URL returned by the provider" do
      @chapa.result = Payments::Providers::Result.unknown(
        provider_reference: "checkout-ref",
        checkout_url: "https://checkout.chapa.test/checkout-ref",
        raw_status: "pending"
      )

      result = start(provider: "chapa", payment_method: "telebirr", key: "checkout-url")

      assert_predicate result, :success?, result.error&.message
      assert_equal "https://checkout.chapa.test/checkout-ref", result.value.checkout_url
    end

    test "records a provider failure and permits the next sequential attempt" do
      @chapa.result = Payments::Providers::Result.failure(
        failure_code: "declined", raw_status: "declined"
      )

      first = start(provider: "chapa", payment_method: "telebirr", key: "failed-1")
      second = start(provider: "chapa", payment_method: "telebirr", key: "failed-2")

      assert_predicate first, :success?, first.error&.message
      assert_equal "failed", first.value.status
      assert_equal 500, first.value.buyer_fee_minor
      assert_predicate second, :success?, second.error&.message
      assert_equal 2, second.value.attempt_number
    end

    test "persists a missing hosted checkout URL as a retryable failed attempt" do
      @chapa.result = Payments::Providers::Result.failure(
        failure_code: "checkout_url_missing", raw_status: "checkout_url_missing"
      )

      first = start(provider: "chapa", payment_method: "telebirr", key: "missing-checkout")
      replay = start(provider: "chapa", payment_method: "telebirr", key: "missing-checkout")

      assert_predicate first, :success?, first.error&.message
      assert_equal "failed", first.value.status
      assert_equal "checkout_url_missing", first.value.failure_code
      assert_equal first.value.id, replay.value.id
      assert_equal 1, @chapa.create_calls.length
    end

    test "rejects a request from a different buyer" do
      result = Orders::StartPaymentAttempt.call(
        order: @order,
        buyer: core_users(:core_admin),
        provider: "chapa",
        payment_method: "telebirr",
        idempotency_key: "wrong-buyer"
      )

      assert_predicate result, :failure?
      assert_equal "payment_order_not_owned", result.error.code
      assert_empty Orders::Payment.where(order: @order)
    end

    test "rejects a new payment attempt after the event is cancelled" do
      @event.update!(status: "cancelled")

      result = start(provider: "chapa", payment_method: "telebirr", key: "cancelled-event")

      assert_predicate result, :failure?
      assert_equal "event_cancelled", result.error.code
      assert_empty Orders::Payment.where(order: @order)
    end

    test "rejects an expired order before creating an attempt" do
      @order.update_columns(status: "draft")
      @order.update_columns(expires_at: @now - 1.minute)
      @order.update_columns(status: "pending_payment")

      result = start(provider: "chapa", payment_method: "telebirr", key: "expired")

      assert_predicate result, :failure?
      assert_equal "payment_attempt_expired", result.error.code
      assert_empty Orders::Payment.where(order: @order)
    end

    test "rejects unsupported provider capabilities" do
      result = start(provider: "stripe", payment_method: "telebirr", key: "unsupported-method")

      assert_predicate result, :failure?
      assert_equal "payment_method_unsupported", result.error.code
      assert_empty Orders::Payment.where(order: @order)
    end

    test "persists and dispatches the canonical CBE Birr payment method" do
      result = start(provider: "chapa", payment_method: "cbebirr", key: "canonical-cbebirr")

      assert_predicate result, :success?, result.error&.message
      assert_equal "cbebirr", result.value.payment_method
      assert_equal "cbebirr", @chapa.create_calls.sole.fetch(:payment_method)
    end

    test "rejects the non-canonical CBE alias before provider dispatch" do
      result = start(provider: "chapa", payment_method: "cbe", key: "alias-cbe")

      assert_predicate result, :failure?
      assert_equal "invalid_payment_method", result.error.code
      assert_empty @chapa.create_calls
      assert_empty Orders::Payment.where(order: @order)
    end

    test "requires a requote when the selected commercial evidence changed" do
      result = start(
        provider: "chapa",
        payment_method: "telebirr",
        key: "changed-quote",
        commercial_signature: "b" * 64
      )

      assert_predicate result, :failure?
      assert_equal "commercial_requote_required", result.error.code
      assert_empty Orders::Payment.where(order: @order)
    end

    test "replays the same idempotency key without another provider call" do
      first = start(provider: "chapa", payment_method: "telebirr", key: "replay")
      replay = start(provider: "chapa", payment_method: "telebirr", key: "replay")

      assert_predicate first, :success?, first.error&.message
      assert_predicate replay, :success?, replay.error&.message
      assert_equal first.value.id, replay.value.id
      assert_equal 1, @chapa.create_calls.length
    end

    test "rejects a changed request under an existing idempotency key" do
      first = start(provider: "chapa", payment_method: "telebirr", key: "conflict")
      conflict = start(provider: "chapa", payment_method: "card", key: "conflict")

      assert_predicate first, :success?, first.error&.message
      assert_predicate conflict, :failure?
      assert_equal "payment_idempotency_conflict", conflict.error.code
      assert_equal 1, @chapa.create_calls.length
    end

    test "supersedes the current attempt and requests provider cancellation before switching" do
      first = start(provider: "chapa", payment_method: "telebirr", key: "switch-1")
      second = start(provider: "stripe", payment_method: "card", key: "switch-2")

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :success?, second.error&.message
      assert_equal 1, first.value.reload.superseded_at.present? ? 1 : 0
      assert_equal 2, second.value.attempt_number
      assert_equal first.value.id, @chapa.cancel_calls.first.fetch(:payment_id)
      assert_equal 1, Orders::Payment.current.where(order: @order).count
      assert_equal second.value.id, Orders::Payment.current.find_by(order: @order).id
    end

    test "does not request cancellation when the provider explicitly disables it" do
      @chapa.capabilities = @chapa.capabilities.merge(cancel: false)

      first = start(provider: "chapa", payment_method: "telebirr", key: "no-cancel-1")
      second = start(provider: "stripe", payment_method: "card", key: "no-cancel-2")

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :success?, second.error&.message
      assert_empty @chapa.cancel_calls
    end

    test "allows at most three attempts" do
      run = -> do
        3.times do |index|
          result = start(provider: "chapa", payment_method: "telebirr", key: "limit-#{index}")
          assert_predicate result, :success?, result.error&.message
        end

        result = start(provider: "chapa", payment_method: "telebirr", key: "limit-4")

        assert_predicate result, :failure?
        assert_equal "payment_attempt_limit_reached", result.error.code
      end

      defined?(Prosopite) ? Prosopite.pause(&run) : run.call
      assert_equal 3, Orders::Payment.where(order: @order).count
      assert_equal 1, Orders::Payment.current.where(order: @order).count
    end

    test "blocks a new attempt after one succeeds and is accepted" do
      @chapa.result = Payments::Providers::Result.success(provider_reference: "accepted-ref", raw_status: "paid")
      first = start(provider: "chapa", payment_method: "telebirr", key: "accepted-1")
      assert_predicate first, :success?, first.error&.message
      first.value.update_columns(accepted_at: @now)

      result = start(provider: "stripe", payment_method: "card", key: "accepted-2")

      assert_predicate result, :failure?
      assert_equal "payment_already_accepted", result.error.code
      assert_equal 1, Orders::Payment.where(order: @order).count
    end

    test "leaves an attempt processing when provider creation raises" do
      @chapa.raise_on_create = Timeout::Error.new("gateway timeout")

      result = start(provider: "chapa", payment_method: "telebirr", key: "raised-timeout")

      assert_predicate result, :success?, result.error&.message
      assert_equal "processing", result.value.reload.status
      assert_equal "provider_exception", result.value.raw_status
      assert_equal 1, Orders::Payment.current.where(order: @order).count
    end

    test "keeps an invalid provider success result processing for verification" do
      @chapa.result = Payments::Providers::Result.success(
        provider_reference: "invalid-fee-ref",
        provider_fee_minor: 1,
        provider_fee_currency: "USD",
        raw_status: "paid"
      )

      result = start(provider: "chapa", payment_method: "telebirr", key: "invalid-provider-result")

      assert_predicate result, :success?, result.error&.message
      assert_equal "processing", result.value.status
      assert_equal "provider_result_invalid", result.value.raw_status
      assert_equal "invalid-fee-ref", result.value.provider_reference
      assert_equal 1, Orders::Payment.current.where(order: @order).count
    end

    test "serializes concurrent starts into one current attempt" do
      ready = Queue.new
      start_signal = Queue.new
      threads = 2.times.map do |index|
        Thread.new do
          ready << true
          start_signal.pop
          Orders::ApplicationRecord.connection_pool.with_connection do
            start(provider: "chapa", payment_method: "telebirr", key: "concurrent-#{index}")
          end
        end
      end

      2.times { ready.pop }
      2.times { start_signal << true }
      results = threads.map(&:value)

      assert results.all?(&:success?), results.map { |result| result.error&.message }
      assert_equal 2, Orders::Payment.where(order: @order).count
      assert_equal 1, Orders::Payment.current.where(order: @order).count
    end

    private

    def start(provider:, payment_method:, key:, commercial_signature: nil)
      Orders::StartPaymentAttempt.call(
        order: @order,
        buyer: @buyer,
        provider:,
        payment_method:,
        commercial_signature:,
        idempotency_key: key,
        at: @now
      )
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
        exchange_rate_expires_at: @now + 10.minutes,
        expires_at: @now + 10.minutes,
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
