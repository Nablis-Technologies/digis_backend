# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  module OutboxHandlers
    class GrantTopUpCreditsTest < ActiveSupport::TestCase
      Event = Data.define(:payload, :event_type)

      setup do
        organization = organizations_organizations(:one)
        buyer = core_users(:super_admin)
        account = CreditAccount.create!(organization:, channel: "sms")
        rate = CreditRateVersion.create!(
          channel: "sms", version: 1, currency: "ETB", unit_price_minor: 10,
          effective_from: 1.hour.ago, status: "active", volume_tiers: [],
          idempotency_key_digest: Digest::SHA256.hexdigest("handler-grant-rate"),
          request_digest: Digest::SHA256.hexdigest("handler-grant-rate-request"), activated_at: 1.hour.ago
        )
        @top_up = CreditTopUp.create!(
          organization:, credit_account: account, rate_version: rate,
          channel: "sms", quantity: 10, currency: "ETB", amount_minor: 100,
          price_digest: Digest::SHA256.hexdigest("handler-grant-price"), status: "pending_payment",
          idempotency_key_digest: Digest::SHA256.hexdigest("handler-grant-top-up"),
          request_digest: Digest::SHA256.hexdigest("handler-grant-request")
        )
        purchase = Orders::BillingPurchase.create!(
          organization:, requested_by: buyer, kind: "messaging_credit_top_up",
          source_type: "Messaging::CreditTopUp", source_id: @top_up.id,
          currency: "ETB", amount_minor: 100, price_digest: @top_up.price_digest,
          status: "pending_payment", idempotency_key_digest: Digest::SHA256.hexdigest("handler-grant-purchase"),
          expires_at: 30.minutes.from_now
        )
        @top_up.update!(billing_purchase: purchase)
        @payment = Orders::Payment.create!(
          billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
          status: "succeeded", amount_minor: 100, currency: "ETB", accepted_at: Time.current,
          succeeded_at: Time.current, billing_purchase_price_digest: purchase.price_digest,
          buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "handler-grant-payment",
          settlement_grace_minutes: 5, settlement_grace_expires_at: purchase.expires_at + 5.minutes
        )
      end

      test "loads the source identity and grants credits through the domain command" do
        event = Event.new(
          payload: {
            "source_type" => "Messaging::CreditTopUp", "source_id" => @top_up.id,
            "payment_id" => @payment.id
          }, event_type: "orders.billing_payment.accepted"
        )

        result = GrantTopUpCredits.call(event:)

        assert_predicate result, :success?, result.error&.message
        assert_equal "paid", @top_up.reload.status
        assert_equal 1, @top_up.credit_account.ledger_entries.where(entry_type: "top_up").count
      end

      test "returns success no-op when top-up is reversed with refund evidence" do
        @top_up.update!(status: "reversed")
        Orders::Refund.create!(
          payment: @payment, type: "payment_reversal", idempotency_key: "handler-grant-refund-evidence",
          amount_minor: @payment.amount_minor, currency: @payment.currency,
          status: "succeeded", reason_code: "late_payment"
        )
        event = Event.new(
          payload: {
            "source_type" => "Messaging::CreditTopUp", "source_id" => @top_up.id,
            "payment_id" => @payment.id
          }, event_type: "orders.billing_payment.accepted"
        )

        result = GrantTopUpCredits.call(event:)

        assert_predicate result, :success?, result.error&.message
        assert_equal "reversed", @top_up.reload.status
        assert_empty @top_up.credit_account.ledger_entries
      end
    end
  end
end
