# frozen_string_literal: true

require "digest"
require "test_helper"

module Orders
  class AcceptBillingPaymentTest < ActiveSupport::TestCase
    setup do
      @organization = organizations_organizations(:one)
      @buyer = core_users(:super_admin)
      @price_digest = Digest::SHA256.hexdigest("accept-quote")
      @purchase = Orders::BillingPurchase.create!(
        organization: @organization, requested_by: @buyer, kind: "messaging_credit_top_up",
        source_type: "Messaging::CreditTopUp", source_id: SecureRandom.uuid,
        currency: "ETB", amount_minor: 1_000, price_digest: @price_digest,
        status: "pending_payment", idempotency_key_digest: Digest::SHA256.hexdigest("accept-purchase"),
        expires_at: 30.minutes.from_now
      )
      @payment = Orders::Payment.create!(
        billing_purchase: @purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "processing", amount_minor: 1_000, currency: "ETB",
        billing_purchase_price_digest: @price_digest, buyer_fee_minor: 0, organizer_fee_minor: 0,
        idempotency_key: "accept-payment", settlement_grace_minutes: 5,
        settlement_grace_expires_at: @purchase.expires_at + 5.minutes,
        provider_reference: "chapa-ref"
      )
    end

    test "accepts billing payment and publishes the credit grant event" do
      result = AcceptBillingPayment.call(payment: @payment)

      assert_predicate result, :success?, result.error&.message
      assert_equal "paid", @purchase.reload.status
      assert @payment.reload.accepted?
      event = Core::OutboxEvent.find_by!(event_type: "orders.billing_payment.accepted", aggregate_id: @payment.id)
      assert_equal @purchase.id, event.payload.fetch("billing_purchase_id")
      assert_equal @purchase.source_id, event.payload.fetch("source_id")
    end

    test "creates a provider refund obligation for a duplicate billing success" do
      @purchase.update!(status: "paid")

      result = AcceptBillingPayment.call(payment: @payment)

      assert_predicate result, :success?, result.error&.message
      assert_equal "succeeded", @payment.reload.status
      refund = Orders::Refund.find_by!(payment: @payment, type: "payment_reversal")
      assert_equal "duplicate_payment", refund.reason_code
      assert Core::OutboxEvent.exists?(event_type: "orders.payment_reversal.created", aggregate_id: @payment.id)
      refute Core::OutboxEvent.exists?(event_type: "orders.billing_payment.reversed", aggregate_id: @payment.id)
    end

    test "creates a provider refund obligation for a late success after expiry" do
      @purchase.update!(expires_at: 1.minute.ago)

      result = AcceptBillingPayment.call(payment: @payment)

      assert_predicate result, :success?, result.error&.message
      assert_equal "succeeded", @payment.reload.status
      assert_equal "reversed", @purchase.reload.status
      assert_equal "late_payment", Orders::Refund.find_by!(payment: @payment).reason_code
    end

    test "returns the reversal failure instead of raising an undefined exception" do
      @purchase.update!(status: "paid")
      reversal_error = Core::BusinessError.new(
        "reversal unavailable", code: "reversal_unavailable", status: :conflict
      )
      result = nil

      Orders::CreatePaymentReversal.expects(:call).returns(
        Core::BaseService::Result.failure(reversal_error)
      )
      result = AcceptBillingPayment.call(payment: @payment)

      assert_predicate result, :failure?
      assert_equal "reversal_unavailable", result.error.code
      assert_equal :conflict, result.error.status
    end
  end
end
