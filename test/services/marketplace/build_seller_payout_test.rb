# frozen_string_literal: true

require "test_helper"

module Marketplace
  class BuildSellerPayoutTest < ActiveSupport::TestCase
    include SellerPayoutTestHelpers

    setup do
      setup_seller_payout_context
    end

    test "requires a verified account and does not fall back to the purchase method" do
      pending_account = create_payout_account(account_number: "1000000000013")
      create_seller_ledger_entry(amount_minor: 10_000)

      result = build_seller_payout(account: pending_account)

      assert_predicate result, :failure?
      assert_equal "payout_account_not_verified", result.error.code
      assert_empty SellerPayout.where(seller_user: @seller)
    end

    test "waits for event completion and the safety buffer" do
      @event.update_columns(completed_at: @now - 6.days)
      create_seller_ledger_entry(amount_minor: 10_000)

      result = build_seller_payout

      assert_predicate result, :failure?
      assert_equal "seller_payout_not_matured", result.error.code
      assert_empty SellerPayout.where(seller_user: @seller)
    end

    test "blocks postponed, suspended, and cancelled events" do
      entry = create_seller_ledger_entry(amount_minor: 10_000)

      @event.update_columns(status: "cancelled", completed_at: nil)
      result = build_seller_payout(idempotency_key: "seller-payout-cancelled")

      assert_predicate result, :failure?
      assert_equal "seller_payout_not_matured", result.error.code
      assert_equal 10_000, entry.reload.amount_minor

      @event.update_columns(status: "completed", completed_at: @now - 8.days)
      event_date = @event.event_dates.create!(
        starts_at: @now - 2.days,
        ends_at: @now - 1.day,
        status: "postponed"
      )
      result = build_seller_payout(idempotency_key: "seller-payout-suspended")

      assert_predicate result, :failure?
      assert_equal "seller_payout_not_matured", result.error.code
      assert_equal "postponed", event_date.reload.status
    end

    test "reserves negative ledger facts before positive proceeds" do
      negative = create_seller_ledger_entry(amount_minor: -1_500, type: "adjustment")
      positive = create_seller_ledger_entry(amount_minor: 10_000, type: "adjustment")

      result = build_seller_payout

      assert_predicate result, :success?, result.error&.message
      payout = result.value
      assert_equal 8_500, payout.amount_minor
      assert_equal [ negative.id, positive.id ], payout.seller_payout_allocations.order(:id).pluck(:seller_ledger_entry_id)
      assert_equal [ 1_500, 10_000 ], payout.seller_payout_allocations.order(:id).pluck(:amount_minor)
    end

    test "keeps payouts in one seller and currency and supports a partial amount" do
      create_seller_ledger_entry(amount_minor: 10_000)
      create_seller_ledger_entry(amount_minor: 2_000, currency: "USD")

      result = build_seller_payout(amount_minor: 4_000)

      assert_predicate result, :success?, result.error&.message
      assert_equal 4_000, result.value.amount_minor
      assert_equal [ 4_000 ], result.value.seller_payout_allocations.pluck(:amount_minor)
      assert_equal "ETB", result.value.currency
    end

    test "replays the same idempotency key without creating another payout" do
      create_seller_ledger_entry(amount_minor: 10_000)

      first = build_seller_payout
      second = build_seller_payout

      assert_predicate first, :success?, first.error&.message
      assert_predicate second, :success?, second.error&.message
      assert_equal first.value.id, second.value.id
      assert_equal 1, SellerPayout.where(idempotency_key: "seller-payout-build-1").count
    end
  end
end
