# frozen_string_literal: true

require "test_helper"

module Orders
  class ProcessPaymentEventTest < ActiveSupport::TestCase
    class WebhookAdapter < Payments::Providers::Adapter
      attr_accessor :webhook_valid, :verification_result
      attr_reader :verification_requests, :verified_payments

      def initialize
        @webhook_valid = true
        @verification_requests = []
        @verified_payments = []
      end

      def verify_webhook(**) = webhook_valid

      def verify(**request)
        verification_requests << request
        return verification_result if verification_result

        references = request.values_at(:provider_reference, :merchant_reference, :idempotency_key).compact
        payment = verified_payments.find do |candidate|
          references.any? do |reference|
            reference.in?([ candidate.provider_reference, candidate.provider_merchant_reference, candidate.idempotency_key ])
          end
        end
        return Payments::Providers::Result.unknown(raw_status: "not_found") unless payment

        Payments::Providers::Result.success(
          provider_reference: request[:provider_reference].presence ||
            payment.provider_reference.presence || "verified-#{payment.id}",
          merchant_reference: payment.provider_merchant_reference,
          amount_minor: payment.amount_minor,
          currency: payment.currency
        )
      end

      def create(**) = Payments::Providers::Result.unknown(raw_status: "pending")

      def cancel(**) = Payments::Providers::Result.cancelled(raw_status: "cancelled")

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
      @adapter.verified_payments << @payment
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

    test "reconciles a Chapa success by the verified merchant reference when webhook omits it" do
      @payment.update!(provider_reference: nil)
      @adapter.verification_result = verified_result(
        @payment,
        provider_reference: "chapa-receipt-reference"
      )
      event = record_event(
        event_id: "chapa-success-without-merchant-reference",
        event_type: "payment.success",
        payload: {
          "webhook_type" => "payment",
          "event" => "payment.success",
          "status" => "success",
          "chapa_reference" => "chapa-receipt-reference",
          "amount" => "42179",
          "currency" => "ETB"
        }
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "processed", event.reload.status
      assert_equal @payment.id, event.payment_id
      assert_equal "chapa-receipt-reference", @payment.reload.provider_reference
      assert @payment.accepted?
      assert_equal "fulfilled", @order.reload.status
      assert_equal "chapa-receipt-reference", @adapter.verification_requests.sole.fetch(:provider_reference)
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

    test "does not fulfill a Chapa success when the verified amount differs" do
      assert_verification_rejected(verified_result(@payment, amount_minor: @payment.amount_minor + 1))
    end

    test "does not fulfill a Chapa success when the verified currency differs" do
      assert_verification_rejected(verified_result(@payment, currency: "USD"))
    end

    test "does not fulfill a Chapa success when the verified merchant reference differs" do
      assert_verification_rejected(verified_result(@payment, merchant_reference: "different-merchant-reference"))
    end

    test "does not replace a stored provider reference with a different verified reference" do
      @payment.update!(provider_reference: "stored-chapa-reference")
      @adapter.verification_result = verified_result(@payment, provider_reference: "different-chapa-reference")
      event = record_event(
        event_id: "chapa-provider-reference-conflict",
        event_type: "payment.success",
        payload: {
          "status" => "success",
          "chapa_reference" => "different-chapa-reference"
        }
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :failure?, result.error&.code
      assert_equal "failed", event.reload.status
      assert_not @payment.reload.accepted?
      assert_equal "stored-chapa-reference", @payment.provider_reference
      assert_equal "pending_payment", @order.reload.status
    end

    test "keeps a Chapa success retryable when provider verification is pending" do
      assert_verification_rejected(
        Payments::Providers::Result.unknown(provider_reference: "chapa-pending-reference", raw_status: "pending")
      )
    end

    test "acquires checkout advisory before mutating an event payment" do
      @payment.update!(provider_reference: nil)
      event = record_event(
        event_id: "evt-checkout-lock-order",
        event_type: "payment.succeeded",
        payload: {
          "status" => "paid",
          "provider_reference" => "verified-reference",
          "merchant_reference" => @payment.provider_merchant_reference
        }
      )
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        statements << payload[:sql]
      end

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      advisory_index = statements.index { |sql| sql.include?("pg_advisory_xact_lock") }
      order_lock_index = statements.index { |sql| sql.match?(/FROM\s+"orders_orders".*FOR UPDATE/i) }
      payment_write_index = statements.index do |sql|
        sql.match?(/(?:UPDATE\s+"orders_payments"|FROM\s+"orders_payments".*FOR UPDATE)/i)
      end

      assert_not_nil advisory_index, "expected the shared checkout advisory lock"
      assert_not_nil order_lock_index, "expected an order row lock"
      assert_not_nil payment_write_index, "expected an authoritative payment write/lock"
      assert_operator advisory_index, :<, order_lock_index
      assert_operator advisory_index, :<, payment_write_index
      assert_equal "verified-reference", @payment.reload.provider_reference
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    test "direct payment acceptance acquires checkout advisory before order and payment locks" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        statements << payload[:sql]
      end

      result = Orders::AcceptPayment.call(payment: @payment)

      assert_predicate result, :success?, result.error&.message
      advisory_index = statements.index { |sql| sql.include?("pg_advisory_xact_lock") }
      order_lock_index = statements.index { |sql| sql.match?(/FROM\s+"orders_orders".*FOR UPDATE/i) }
      event_lock_index = statements.index { |sql| sql.match?(/FROM\s+"events_events".*FOR UPDATE/i) }
      payment_lock_index = statements.index { |sql| sql.match?(/FROM\s+"orders_payments".*FOR UPDATE/i) }

      assert_not_nil advisory_index, "expected the shared checkout advisory lock"
      assert_not_nil order_lock_index, "expected an order row lock"
      assert_not_nil event_lock_index, "expected an event row lock"
      assert_not_nil payment_lock_index, "expected a payment row lock"
      assert_operator advisory_index, :<, order_lock_index
      assert_operator order_lock_index, :<, event_lock_index
      assert_operator event_lock_index, :<, payment_lock_index
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    test "locates a webhook by the persisted provider merchant reference" do
      @payment.update!(provider_reference: nil)
      event = record_event(event_id: "evt-merchant-ref", event_type: "payment.succeeded", payload: {
        "status" => "paid", "merchant_reference" => "merchant-ref"
      })

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal @payment.id, event.reload.payment_id
      assert @payment.reload.accepted?
    end

    test "persists a provider reference from a directly correlated Chapa event before fulfillment" do
      @payment.update!(provider_reference: nil)
      event = record_event(
        event_id: "chapa-provider-reference-event",
        event_type: "payment.succeeded",
        payload: {
          "status" => "success",
          "merchant_reference" => @payment.provider_merchant_reference,
          "chapa_reference" => "chapa-provider-reference"
        }
      )
      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "processed", event.reload.status
      assert_equal @payment.id, event.payment_id
      assert_equal "chapa-provider-reference", @payment.reload.provider_reference
      assert @payment.accepted?
    end

    test "accepts a billing payment without fulfilling an event order" do
      purchase = Orders::BillingPurchase.create!(
        organization: organizations_organizations(:one), requested_by: @buyer,
        kind: "messaging_credit_top_up", source_type: "Messaging::CreditTopUp", source_id: SecureRandom.uuid,
        currency: "ETB", amount_minor: 100, price_digest: "b" * 64,
        status: "pending_payment", idempotency_key_digest: SecureRandom.hex(32), expires_at: 30.minutes.from_now
      )
      payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "processing", amount_minor: 100, currency: "ETB", billing_purchase_price_digest: "b" * 64,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "billing-process-payment",
        provider_reference: "billing-chapa-ref", provider_merchant_reference: "bill-merchant-ref",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )
      @adapter.verified_payments << payment
      event = Orders::PaymentEvent.create!(
        payment:, provider: "chapa", provider_event_id: "billing-process-event",
        event_type: "payment.succeeded", status: "received", payload: {
          "status" => "paid", "provider_reference" => payment.provider_reference,
          "merchant_reference" => payment.provider_merchant_reference
        },
        payload_digest: "c" * 64, received_at: Time.current
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "paid", purchase.reload.status
      assert payment.reload.accepted?
      assert Core::OutboxEvent.exists?(event_type: "orders.billing_payment.accepted", aggregate_id: payment.id)
      assert_equal "pending_payment", @order.reload.status
    end

    test "keeps an accepted billing reversal as succeeded provider evidence" do
      purchase = Orders::BillingPurchase.create!(
        organization: organizations_organizations(:one), requested_by: @buyer,
        kind: "messaging_credit_top_up", source_type: "Messaging::CreditTopUp", source_id: SecureRandom.uuid,
        currency: "ETB", amount_minor: 100, price_digest: "d" * 64,
        status: "paid", idempotency_key_digest: SecureRandom.hex(32), expires_at: 30.minutes.from_now
      )
      payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 100, currency: "ETB", accepted_at: Time.current,
        succeeded_at: Time.current, billing_purchase_price_digest: "d" * 64,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "billing-reversal-event",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )
      event = Orders::PaymentEvent.create!(
        payment:, provider: "chapa", provider_event_id: "billing-reversal-event-id",
        event_type: "payment.refunded", status: "received", payload: { "status" => "refunded" },
        payload_digest: "e" * 64, received_at: Time.current
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "succeeded", payment.reload.status
      assert_equal "reversed", purchase.reload.status
      assert Core::OutboxEvent.exists?(event_type: "orders.billing_payment.reversed", aggregate_id: payment.id)
    end

    test "does not reverse a paid billing purchase when an unaccepted duplicate payment is reversed" do
      purchase = Orders::BillingPurchase.create!(
        organization: organizations_organizations(:one), requested_by: @buyer,
        kind: "messaging_credit_top_up", source_type: "Messaging::CreditTopUp", source_id: SecureRandom.uuid,
        currency: "ETB", amount_minor: 100, price_digest: "e" * 64,
        status: "paid", idempotency_key_digest: SecureRandom.hex(32), expires_at: 30.minutes.from_now
      )
      accepted_payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", accepted_at: Time.current, succeeded_at: Time.current,
        amount_minor: 100, currency: "ETB", billing_purchase_price_digest: "e" * 64,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "billing-acc-payment",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )
      duplicate_payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 2, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", accepted_at: nil, succeeded_at: Time.current,
        amount_minor: 100, currency: "ETB", billing_purchase_price_digest: "e" * 64,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "billing-dup-reversal",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )
      event = Orders::PaymentEvent.create!(
        payment: duplicate_payment, provider: "chapa", provider_event_id: "billing-dup-reversal-event",
        event_type: "payment.refunded", status: "received", payload: { "status" => "refunded" },
        payload_digest: "d" * 64, received_at: Time.current
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "succeeded", duplicate_payment.reload.status
      assert_equal "paid", purchase.reload.status
      assert_not Core::OutboxEvent.exists?(event_type: "orders.billing_payment.reversed", aggregate_id: duplicate_payment.id)
    end

    test "does not downgrade a paid billing purchase for a failed retry" do
      purchase = Orders::BillingPurchase.create!(
        organization: organizations_organizations(:one), requested_by: @buyer,
        kind: "messaging_credit_top_up", source_type: "Messaging::CreditTopUp", source_id: SecureRandom.uuid,
        currency: "ETB", amount_minor: 100, price_digest: "f" * 64,
        status: "paid", idempotency_key_digest: SecureRandom.hex(32), expires_at: 30.minutes.from_now
      )
      payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 2, provider: "chapa", payment_method: "telebirr",
        status: "processing", amount_minor: 100, currency: "ETB", billing_purchase_price_digest: "f" * 64,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "billing-failed-retry",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )
      event = Orders::PaymentEvent.create!(
        payment:, provider: "chapa", provider_event_id: "billing-failed-retry-event",
        event_type: "payment.failed", status: "received", payload: { "status" => "failed" },
        payload_digest: "a" * 64, received_at: Time.current
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "paid", purchase.reload.status
      assert_equal "failed", payment.reload.status
    end

    test "does not close a billing purchase while another attempt is current" do
      purchase = Orders::BillingPurchase.create!(
        organization: organizations_organizations(:one), requested_by: @buyer,
        kind: "messaging_credit_top_up", source_type: "Messaging::CreditTopUp", source_id: SecureRandom.uuid,
        currency: "ETB", amount_minor: 100, price_digest: "b" * 64,
        status: "pending_payment", idempotency_key_digest: SecureRandom.hex(32), expires_at: 30.minutes.from_now
      )
      failed_attempt = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "processing", amount_minor: 100, currency: "ETB", billing_purchase_price_digest: "b" * 64,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "billing-superseded-failure",
        superseded_at: 1.minute.ago, settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )
      Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 2, provider: "chapa", payment_method: "telebirr",
        status: "processing", amount_minor: 100, currency: "ETB", billing_purchase_price_digest: "b" * 64,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "billing-current-attempt",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )
      event = Orders::PaymentEvent.create!(
        payment: failed_attempt, provider: "chapa", provider_event_id: "billing-superseded-failure-event",
        event_type: "payment.failed", status: "received", payload: { "status" => "failed" },
        payload_digest: "c" * 64, received_at: Time.current
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "pending_payment", purchase.reload.status
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

    test "locates a Chapa V2 webhook payment by its merchant reference" do
      event = record_event(
        event_id: "chapa-v2-merchant-reference-event",
        event_type: "payment.succeeded",
        payload: { "status" => "success", "merchant_reference" => @payment.provider_merchant_reference }
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "fulfilled", @order.reload.status
      assert_equal "succeeded", @payment.reload.status
    end

    test "keeps a blocked Chapa V2 webhook retryable" do
      event = record_event(
        event_id: "chapa-v2-blocked-event",
        event_type: "payment.blocked",
        payload: {
          "status" => "blocked", "merchant_reference" => @payment.idempotency_key,
          "chapa_reference" => "blocked-ref"
        }
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      assert_equal "processing", @payment.reload.status
      assert_equal "pending_payment", @order.reload.status
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

    test "includes billing source identity in billing failure events" do
      purchase = Orders::BillingPurchase.create!(
        organization: organizations_organizations(:one), requested_by: @buyer,
        kind: "messaging_credit_top_up", source_type: "Messaging::CreditTopUp", source_id: SecureRandom.uuid,
        currency: "ETB", amount_minor: 100, price_digest: "b" * 64,
        status: "pending_payment", idempotency_key_digest: SecureRandom.hex(32), expires_at: 30.minutes.from_now
      )
      payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "processing", amount_minor: 100, currency: "ETB", billing_purchase_price_digest: "b" * 64,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "billing-failure-payload",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )
      event = Orders::PaymentEvent.create!(
        payment:, provider: "chapa", provider_event_id: "billing-failure-payload-event",
        event_type: "payment.failed", status: "received", payload: { "status" => "failed" },
        payload_digest: "d" * 64, received_at: Time.current
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :success?, result.error&.message
      outbox = Core::OutboxEvent.find_by!(event_type: "orders.billing_payment.failed", aggregate_id: payment.id)
      assert_equal "Messaging::CreditTopUp", outbox.payload.fetch("source_type")
      assert_equal purchase.source_id, outbox.payload.fetch("source_id")
      assert_equal purchase.id, outbox.payload.fetch("billing_purchase_id")
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
        payload: payload || {
          "status" => "paid", "provider_reference" => @payment.provider_reference,
          "merchant_reference" => @payment.provider_merchant_reference
        },
        raw_payload: JSON.generate(payload || {
          status: "paid", provider_reference: @payment.provider_reference,
          merchant_reference: @payment.provider_merchant_reference
        }),
        signature: "valid-signature",
        headers: { "X-Provider-Signature" => "valid-signature" }
      ).then { |result| result.success? ? result.value : result }
    end

    def verified_result(payment, provider_reference: "chapa-reference", merchant_reference: payment.provider_merchant_reference,
      amount_minor: payment.amount_minor, currency: payment.currency)
      Payments::Providers::Result.success(
        provider_reference:, merchant_reference:, amount_minor:, currency:
      )
    end

    def assert_verification_rejected(verification)
      @payment.update!(provider_reference: nil)
      @adapter.verification_result = verification
      event = record_event(
        event_id: "chapa-verification-rejected-#{SecureRandom.hex(4)}",
        event_type: "payment.success",
        payload: {
          "webhook_type" => "payment",
          "event" => "payment.success",
          "status" => "success",
          "chapa_reference" => verification.provider_reference
        }
      )

      result = Orders::ProcessPaymentEvent.call(event:)

      assert_predicate result, :failure?, result.error&.code
      assert_equal "failed", event.reload.status
      assert_not event.terminal?
      assert_not @payment.reload.accepted?
      assert_equal "pending_payment", @order.reload.status
      assert_empty Ticketing::Ticket.where(order_item_id: Orders::OrderItem.where(order_id: @order.id).select(:id))
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
        provider_merchant_reference: "merchant-ref",
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @order.expires_at + 5.minutes
      }
    end
  end
end
