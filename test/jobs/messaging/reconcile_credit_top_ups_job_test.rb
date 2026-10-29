# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class ReconcileCreditTopUpsJobTest < ActiveJob::TestCase
    setup do
      @organization = organizations_organizations(:one)
      @buyer = core_users(:super_admin)
      @account = CreditAccount.create!(organization: @organization, channel: "sms")
      @rate = CreditRateVersion.create!(
        channel: "sms", version: 1, currency: "ETB", unit_price_minor: 1,
        effective_from: 1.hour.ago, status: "active", volume_tiers: [],
        idempotency_key_digest: Digest::SHA256.hexdigest("top-job-rate"),
        request_digest: Digest::SHA256.hexdigest("top-job-rate-request"), activated_at: 1.hour.ago
      )
      price_digest = Digest::SHA256.hexdigest("top-job-price")
      @top_up = CreditTopUp.create!(
        organization: @organization, credit_account: @account, rate_version: @rate,
        channel: "sms", quantity: 10, currency: "ETB", amount_minor: 10,
        price_digest:, status: "paid", idempotency_key_digest: Digest::SHA256.hexdigest("top-job-top-up"),
        request_digest: Digest::SHA256.hexdigest("top-job-request")
      )
      purchase = Orders::BillingPurchase.create!(
        organization: @organization, requested_by: @buyer, kind: "messaging_credit_top_up",
        source_type: "Messaging::CreditTopUp", source_id: @top_up.id,
        currency: "ETB", amount_minor: 10, price_digest:,
        status: "paid", idempotency_key_digest: Digest::SHA256.hexdigest("top-job-purchase"), expires_at: 30.minutes.from_now
      )
      @top_up.update!(billing_purchase: purchase)
      @payment = Orders::Payment.create!(
        billing_purchase: purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 10, currency: "ETB", accepted_at: Time.current,
        succeeded_at: Time.current, billing_purchase_price_digest: price_digest,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "top-job-payment",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )
      @top_up.update!(accepted_payment: @payment)
    end

    test "reconciles a paid top-up that has no grant" do
      ReconcileCreditTopUpsJob.perform_now

      assert_equal 1, @account.reload.ledger_entries.where(entry_type: "top_up").count
      assert_equal "paid", @top_up.reload.status
    end

    test "reconciles a failed top-up with an accepted billing payment" do
      @top_up.update!(status: "failed")
      @payment.update!(status: "succeeded", accepted_at: Time.current, succeeded_at: Time.current)
      @top_up.billing_purchase.update!(status: "paid")

      ReconcileCreditTopUpsJob.perform_now

      assert_equal "reversed", @top_up.reload.status
      assert_equal "succeeded", @payment.reload.status
      assert Orders::Refund.exists?(payment: @payment, type: "payment_reversal")
    end

    test "grants a pending top-up whose billing payment was accepted" do
      @top_up.update!(status: "pending_payment")
      @payment.update!(status: "succeeded", accepted_at: Time.current, succeeded_at: Time.current)
      @top_up.billing_purchase.update!(status: "paid")

      ReconcileCreditTopUpsJob.perform_now

      assert_equal "paid", @top_up.reload.status
      assert_equal 1, @account.reload.ledger_entries.where(entry_type: "top_up").count
    end

    test "sweeps unaccepted succeeded duplicate billing payments and creates reversal refunds" do
      duplicate_payment = Orders::Payment.create!(
        billing_purchase: @top_up.billing_purchase, attempt_number: 2, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 10, currency: "ETB", accepted_at: nil,
        succeeded_at: Time.current, billing_purchase_price_digest: @top_up.price_digest,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "top-job-payment-dup",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )

      ReconcileCreditTopUpsJob.perform_now

      assert_equal "succeeded", duplicate_payment.reload.status
      assert_nil duplicate_payment.accepted_at
      refund = Orders::Refund.find_by(payment: duplicate_payment, type: "payment_reversal")
      assert_not_nil refund
      assert_equal "duplicate_payment", refund.reason_code
    end
  end
end
