# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class ResolveTopUpPaymentTest < ActiveSupport::TestCase
    setup do
      @organization = organizations_organizations(:one)
      @buyer = core_users(:super_admin)
      price_digest = Digest::SHA256.hexdigest("resolve-quote")
      @account = CreditAccount.create!(organization: @organization, channel: "sms")
      @rate = CreditRateVersion.create!(
        channel: "sms", version: 1, currency: "ETB", unit_price_minor: 10,
        effective_from: 1.hour.ago, status: "active", volume_tiers: [],
        idempotency_key_digest: Digest::SHA256.hexdigest("resolve-rate"),
        request_digest: Digest::SHA256.hexdigest("resolve-rate-request"), activated_at: 1.hour.ago
      )
      @top_up = CreditTopUp.create!(
        organization: @organization, credit_account: @account, rate_version: @rate,
        channel: "sms", quantity: 10, currency: "ETB", amount_minor: 100,
        price_digest:, status: "paid", idempotency_key_digest: Digest::SHA256.hexdigest("resolve-top-up"),
        request_digest: Digest::SHA256.hexdigest("resolve-request")
      )
      @purchase = Orders::BillingPurchase.create!(
        organization: @organization, requested_by: @buyer, kind: "messaging_credit_top_up",
        source_type: "Messaging::CreditTopUp", source_id: @top_up.id,
        currency: "ETB", amount_minor: 100, price_digest: price_digest,
        status: "paid", idempotency_key_digest: Digest::SHA256.hexdigest("resolve-purchase"),
        expires_at: 30.minutes.from_now
      )
      @top_up.update!(billing_purchase: @purchase)
      @payment = Orders::Payment.create!(
        billing_purchase: @purchase, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "reversed", amount_minor: 100, currency: "ETB", billing_purchase_price_digest: price_digest,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "resolve-payment",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )
      @top_up.update!(billing_purchase: @purchase, accepted_payment: @payment)
      CreditLedgerEntry.create!(
        credit_account: @account, rate_version: @rate, entry_type: "top_up", quantity: 10,
        available_delta: 10, reference_type: "Messaging::CreditTopUp", reference_id: @top_up.id,
        idempotency_key_digest: Digest::SHA256.hexdigest("resolve-grant"), metadata: {}
      )
    end

    test "marks failed payment without granting credits" do
      @top_up.update!(status: "pending_payment")
      result = ResolveTopUpPayment.call(top_up: @top_up, payment: @payment, outcome: "failed")

      assert_predicate result, :success?, result.error&.message
      assert_equal "failed", @top_up.reload.status
    end

    test "ignores a failed superseded attempt while another payment is current" do
      @top_up.update!(status: "pending_payment")
      @payment.update!(status: "processing", accepted_at: nil, succeeded_at: nil, superseded_at: 1.minute.ago)
      Orders::Payment.create!(
        billing_purchase: @purchase, attempt_number: 2, provider: "chapa", payment_method: "telebirr",
        status: "processing", amount_minor: 100, currency: "ETB", billing_purchase_price_digest: @purchase.price_digest,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "resolve-current-payment",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )

      result = ResolveTopUpPayment.call(top_up: @top_up, payment: @payment, outcome: "failed")

      assert_predicate result, :success?, result.error&.message
      assert_equal "pending_payment", @top_up.reload.status
    end

    test "ignores a failed retry after the top-up was already paid" do
      result = ResolveTopUpPayment.call(top_up: @top_up, payment: @payment, outcome: "failed")

      assert_predicate result, :success?, result.error&.message
      assert_equal "paid", @top_up.reload.status
      assert_equal 10, @account.reload.ledger_entries.sum(:available_delta)
      assert_empty @account.reload.ledger_entries.where(entry_type: "refund")
    end

    test "records a negative balance when reversed credits were already spent" do
      CreditLedgerEntry.create!(
        credit_account: @account, rate_version: @rate, entry_type: "consume", quantity: 10,
        available_delta: -10, reference_type: "Messaging::CreditTopUp", reference_id: @top_up.id,
        idempotency_key_digest: Digest::SHA256.hexdigest("resolve-consume"), metadata: {}
      )

      result = ResolveTopUpPayment.call(top_up: @top_up, payment: @payment, outcome: "reversed")

      assert_predicate result, :success?, result.error&.message
      assert_equal "reversed", @top_up.reload.status
      assert_equal(-10, @account.reload.ledger_entries.sum(:available_delta))
    end

    test "records a late reversal as one compensating ledger entry" do
      operation = -> { ResolveTopUpPayment.call(top_up: @top_up, payment: @payment, outcome: "reversed") }

      assert_idempotent(operation, counter: -> { CreditLedgerEntry.where(entry_type: "refund").count })
      assert_equal "reversed", @top_up.reload.status
      assert_equal 0, @account.reload.ledger_entries.sum(:available_delta)
    end

    test "ignores a duplicate payment reversal when another payment was accepted" do
      duplicate_payment = Orders::Payment.create!(
        billing_purchase: @purchase, attempt_number: 2, provider: "chapa", payment_method: "telebirr",
        status: "reversed", amount_minor: 100, currency: "ETB", billing_purchase_price_digest: @purchase.price_digest,
        buyer_fee_minor: 0, organizer_fee_minor: 0, idempotency_key: "resolve-dup-payment",
        settlement_grace_minutes: 5, settlement_grace_expires_at: 30.minutes.from_now
      )

      result = ResolveTopUpPayment.call(top_up: @top_up, payment: duplicate_payment, outcome: "reversed")

      assert_predicate result, :success?, result.error&.message
      assert_equal "paid", @top_up.reload.status
      assert_equal 10, @account.reload.ledger_entries.sum(:available_delta)
      assert_empty @account.reload.ledger_entries.where(entry_type: "refund")
    end
  end
end
