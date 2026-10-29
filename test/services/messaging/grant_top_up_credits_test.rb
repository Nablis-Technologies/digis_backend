# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class GrantTopUpCreditsTest < ActiveSupport::TestCase
    setup do
      @organization = organizations_organizations(:one)
      @buyer = core_users(:super_admin)
      @price_digest = Digest::SHA256.hexdigest("grant-quote")
      @account = CreditAccount.create!(organization: @organization, channel: "sms")
      @rate = CreditRateVersion.create!(
        channel: "sms", version: 1, currency: "ETB", unit_price_minor: 10,
        effective_from: 1.hour.ago, status: "active", volume_tiers: [],
        idempotency_key_digest: Digest::SHA256.hexdigest("grant-rate"),
        request_digest: Digest::SHA256.hexdigest("grant-rate-request"), activated_at: 1.hour.ago
      )
      @top_up = CreditTopUp.create!(
        organization: @organization, credit_account: @account, rate_version: @rate,
        channel: "sms", quantity: 10, currency: "ETB", amount_minor: 100,
        price_digest: @price_digest, status: "pending_payment",
        idempotency_key_digest: Digest::SHA256.hexdigest("grant-top-up"),
        request_digest: Digest::SHA256.hexdigest("grant-request")
      )
      @purchase = Orders::BillingPurchase.create!(
        organization: @organization, requested_by: @buyer, kind: "messaging_credit_top_up",
        source_type: "Messaging::CreditTopUp", source_id: @top_up.id,
        currency: "ETB", amount_minor: 100, price_digest: @price_digest,
        status: "pending_payment", idempotency_key_digest: Digest::SHA256.hexdigest("grant-purchase"),
        expires_at: 30.minutes.from_now
      )
      @top_up.update!(billing_purchase: @purchase)
      @payment = Orders::Payment.create!(
        billing_purchase: @purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 100, currency: "ETB", accepted_at: Time.current,
        succeeded_at: Time.current, billing_purchase_price_digest: @price_digest,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "grant-payment",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )
    end

    test "grants once and replays without a second ledger row" do
      operation = -> { GrantTopUpCredits.call(top_up: @top_up, payment: @payment) }

      assert_idempotent(operation, counter: -> { CreditLedgerEntry.where(entry_type: "top_up").count })
      assert_equal "paid", @top_up.reload.status
      assert_equal 10, @account.reload.ledger_entries.where(entry_type: "top_up").sum(:quantity)
    end

    test "treats a reversed top-up with refund evidence as an idempotent no-op" do
      @top_up.update!(status: "reversed")
      Orders::Refund.create!(
        payment: @payment, type: "payment_reversal", idempotency_key: "grant-refund-evidence",
        amount_minor: @payment.amount_minor, currency: @payment.currency,
        status: "succeeded", reason_code: "late_payment"
      )

      result = GrantTopUpCredits.call(top_up: @top_up, payment: @payment)

      assert_predicate result, :success?, result.error&.message
      assert_equal "reversed", result.value.status
      assert_empty @account.reload.ledger_entries
    end

    test "does not ignore a reversed top-up without refund evidence" do
      @top_up.update!(status: "reversed")

      result = GrantTopUpCredits.call(top_up: @top_up, payment: @payment)

      assert_predicate result, :failure?
      assert_equal "top_up_payment_mismatch", result.error.code
    end
  end
end
