# frozen_string_literal: true

require "digest"
require "test_helper"

module Orders
  class PaymentRefreshServiceTest < ActiveSupport::TestCase
    class BlockedThrottle
      def allowed?(payment_id:)
        false
      end
    end

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @order = Orders::Order.create!(order_attributes)
      @payment = Orders::Payment.create!(payment_attributes)
      @provider = ::Payments::Providers::FakePaymentProvider.new(
        outcomes: { verify: [ ::Payments::Providers::Result.success(provider_reference: "provider-ref") ] }
      )
      ::Payments::Providers::Registry.register("chapa", @provider)
    end

    teardown do
      ::Payments::Providers::Registry.instance_variable_set(:@adapters, {})
    end

    test "returns an accepted payment without calling the provider" do
      @payment.update!(status: "succeeded", succeeded_at: Time.current, accepted_at: Time.current)

      result = PaymentRefresh.call(payment: @payment, buyer: @buyer, idempotency_key: "refresh-terminal")

      assert_predicate result, :success?, result.error&.message
      assert_equal "pending", result.value.fetch(:state)
      assert_equal @payment.id, result.value.fetch(:payment).id
      assert_empty @provider.requests_for(@payment.idempotency_key)
    end

    test "verifies a pending payment using its stored provider reference" do
      process = ::Core::BaseService::Result.success(@payment)
      Orders::ProcessPaymentEvent.expects(:call).with(event_id: kind_of(String)).returns(process)

      result = PaymentRefresh.call(payment: @payment, buyer: @buyer, idempotency_key: "refresh-pending")

      assert_predicate result, :success?, result.error&.message
      assert_equal "pending", result.value.fetch(:state)
      assert_equal [ { provider_reference: "provider-ref", idempotency_key: "provider-ref" } ],
                   @provider.requests_for("provider-ref")
    end

    test "returns a typed failure when the provider cannot be verified" do
      ::Payments::Providers::Registry.instance_variable_set(:@adapters, {})

      result = PaymentRefresh.call(payment: @payment, buyer: @buyer, idempotency_key: "refresh-unavailable")

      assert_predicate result, :failure?
      assert_equal "provider_unavailable", result.error.code
      assert_equal :service_unavailable, result.error.status
    end

      test "returns current state without a provider call while throttled" do
      result = PaymentRefresh.call(
        payment: @payment, buyer: @buyer, idempotency_key: "refresh-throttled", throttle: BlockedThrottle.new
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "pending", result.value.fetch(:state)
        assert_empty @provider.requests_for(@payment.idempotency_key)
      end

      test "returns a terminal state for a failed payment without calling the provider" do
        @payment.update!(status: "failed", failure_code: "declined")

        result = PaymentRefresh.call(payment: @payment, buyer: @buyer, idempotency_key: "refresh-failed")

        assert_predicate result, :success?, result.error&.message
        assert_equal "terminal", result.value.fetch(:state)
        assert_empty @provider.requests_for(@payment.idempotency_key)
      end

      test "rejects billing payments" do
        purchase = Orders::BillingPurchase.create!(
          organization: organizations_organizations(:two), requested_by: @buyer,
          kind: "messaging_credit_top_up", source_type: "Messaging::CreditTopUp", source_id: SecureRandom.uuid,
          currency: "ETB", amount_minor: 100, price_digest: "b" * 64, status: "pending_payment",
          idempotency_key_digest: Digest::SHA256.hexdigest("refresh-billing"), expires_at: 10.minutes.from_now
        )
        billing_payment = Orders::Payment.create!(
          billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
          status: "processing", amount_minor: 100, currency: "ETB", billing_purchase_price_digest: purchase.price_digest,
          buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "billing-refresh",
          settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
        )

        result = PaymentRefresh.call(payment: billing_payment, buyer: @buyer, idempotency_key: "refresh-billing")

        assert_predicate result, :failure?
        assert_equal "event_payment_required", result.error.code
      end

      test "rejects an invalid idempotency key" do
        result = PaymentRefresh.call(payment: @payment, buyer: @buyer, idempotency_key: " ")

        assert_predicate result, :failure?
        assert_equal "invalid_idempotency_key", result.error.code
      end

    test "rejects a payment belonging to another buyer" do
      result = PaymentRefresh.call(payment: @payment, buyer: core_users(:support), idempotency_key: "refresh-owner")

      assert_predicate result, :failure?
      assert_equal "payment_order_not_owned", result.error.code
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
        idempotency_key_digest: Digest::SHA256.hexdigest("refresh-order"),
        creation_request_digest: Digest::SHA256.hexdigest("refresh-order-request")
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
        idempotency_key: "tx-ref",
        provider_reference: "provider-ref",
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: @order.expires_at + 5.minutes
      }
    end
  end
end
