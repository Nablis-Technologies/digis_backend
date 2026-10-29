# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  module OutboxHandlers
    class ResolveTopUpPaymentTest < ActiveSupport::TestCase
      Event = Data.define(:payload, :event_type)

      setup do
        organization = organizations_organizations(:one)
        buyer = core_users(:super_admin)
        account = CreditAccount.create!(organization:, channel: "sms")
        rate = CreditRateVersion.create!(
          channel: "sms", version: 1, currency: "ETB", unit_price_minor: 10,
          effective_from: 1.hour.ago, status: "active", volume_tiers: [],
          idempotency_key_digest: Digest::SHA256.hexdigest("handler-resolve-rate"),
          request_digest: Digest::SHA256.hexdigest("handler-resolve-rate-request"), activated_at: 1.hour.ago
        )
        @top_up = CreditTopUp.create!(
          organization:, credit_account: account, rate_version: rate,
          channel: "sms", quantity: 10, currency: "ETB", amount_minor: 100,
          price_digest: Digest::SHA256.hexdigest("handler-resolve-price"), status: "pending_payment",
          idempotency_key_digest: Digest::SHA256.hexdigest("handler-resolve-top-up"),
          request_digest: Digest::SHA256.hexdigest("handler-resolve-request")
        )
        purchase = Orders::BillingPurchase.create!(
          organization:, requested_by: buyer, kind: "messaging_credit_top_up",
          source_type: "Messaging::CreditTopUp", source_id: @top_up.id,
          currency: "ETB", amount_minor: 100, price_digest: @top_up.price_digest,
          status: "pending_payment", idempotency_key_digest: Digest::SHA256.hexdigest("handler-resolve-purchase"),
          expires_at: 30.minutes.from_now
        )
        @top_up.update!(billing_purchase: purchase)
        @payment = Orders::Payment.create!(
          billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
          status: "failed", amount_minor: 100, currency: "ETB", billing_purchase_price_digest: purchase.price_digest,
          buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "handler-resolve-payment",
          settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
        )
      end

      test "resolves a failure using billing_purchase_id when source_id is absent" do
        event = Event.new(
          payload: { "billing_purchase_id" => @top_up.orders_billing_purchase_id, "payment_id" => @payment.id },
          event_type: "orders.billing_payment.failed"
        )

        result = ResolveTopUpPayment.call(event:)

        assert_predicate result, :success?, result.error&.message
        assert_equal "failed", @top_up.reload.status
      end

      test "ignores a billing event owned by another product" do
        event = Event.new(
          payload: {
            "source_type" => "Marketing::FeaturedPlacement", "source_id" => "missing",
            "billing_purchase_id" => "missing", "payment_id" => "missing"
          }, event_type: "orders.billing_payment.failed"
        )

        result = ResolveTopUpPayment.call(event:)

        assert_predicate result, :success?, result.error&.message
        assert_nil result.value
      end
    end
  end
end
