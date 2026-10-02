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

    test "makes available seller-ledger facts withdrawable before event completion" do
      @event.update_columns(status: "published", completed_at: nil)
      create_seller_ledger_entry(amount_minor: 10_000)

      result = build_seller_payout

      assert_predicate result, :success?, result.error&.message
      assert_equal 10_000, result.value.amount_minor
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

    test "conflicts when the same idempotency key changes payout amount" do
      create_seller_ledger_entry(amount_minor: 10_000)

      first = build_seller_payout
      changed = build_seller_payout(amount_minor: 1_000)

      assert_predicate first, :success?, first.error&.message
      assert_predicate changed, :failure?
      assert_equal "seller_payout_build_conflict", changed.error.code
    end

    test "conflicts when the same idempotency key changes event scope" do
      create_seller_ledger_entry(amount_minor: 10_000)
      other_event = events_events(:draft_concert)
      create_seller_ledger_entry(amount_minor: 5_000, event: other_event)

      first = build_seller_payout
      changed = build_seller_payout(event: other_event)

      assert_predicate first, :success?, first.error&.message
      assert_predicate changed, :failure?
      assert_equal "seller_payout_build_conflict", changed.error.code
    end
  end

  class BuildSellerPayoutFromResaleTest < ActiveSupport::TestCase
    include ResaleFulfillmentTestHelpers

    class SuccessfulAdapter < Marketplace::PayoutProviders::Adapter
      def available_balance(**) = nil

      def capabilities = { balance_api: { supported: false } }

      def payout(**)
        Marketplace::PayoutProviders::Result.success(provider_reference: "cross-event-test-payout")
      end
    end

    setup do
      setup_resale_fulfillment_context
      number = "1000000000098"
      @account = SellerPayoutAccount.create!(
        user: @owner,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: number,
        account_number_digest: Core::PayoutAccountDigest.call(
          namespace: @owner.id, account_number: number
        ),
        holder_name: "Seller Holder",
        status: "verified",
        verification_source: "test_fixture",
        verified_at: Time.current,
        is_default: true
      )
    end

    test "resale proceeds are payout eligible before event completion" do
      sale_result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)
      assert_predicate sale_result, :success?, sale_result.error&.message
      sale = sale_result.value
      refute_equal "completed", @event.reload.status
      ledger_entries = SellerLedgerEntry.where(resale_sale_id: sale.id)
      assert_equal 2, ledger_entries.count
      assert_equal [ @owner.id ], ledger_entries.distinct.pluck(:seller_user_id)
      assert_equal [ @event.id ], ledger_entries.distinct.pluck(:event_id)

      result = BuildSellerPayout.call(
        seller: @owner,
        account: @account,
        currency: "ETB",
        idempotency_key: "seller-payout-resale-#{sale.id}",
        cutoff_at: Time.current,
        at: Time.current
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal sale.seller_proceeds_minor, result.value.amount_minor
      assert_equal [ "marketplace_fee", "resale_proceeds" ],
        result.value.seller_payout_allocations.includes(:seller_ledger_entry)
          .map { |allocation| allocation.seller_ledger_entry.type }.sort
    end

    test "positive fee reversals restore seller proceeds to immediate withdrawal" do
      sale_result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)
      assert_predicate sale_result, :success?, sale_result.error&.message
      sale = sale_result.value
      proceeds = SellerLedgerEntry.find_by!(resale_sale: sale, type: "resale_proceeds")
      fee = SellerLedgerEntry.find_by!(resale_sale: sale, type: "marketplace_fee")

      [ [ proceeds, -proceeds.amount_minor ], [ fee, -fee.amount_minor ] ].each do |entry, amount|
        SellerLedgerEntry.create!(
          seller_user: @owner,
          event: @event,
          resale_sale: sale,
          reverses_entry: entry,
          type: "cancellation_reversal",
          amount_minor: amount,
          currency: entry.currency,
          available_at: Time.current,
          idempotency_key: "seller-payout-reversal-#{entry.id}",
          description: "Test cancellation reversal",
          created_at: Time.current
        )
      end
      SellerLedgerEntry.create!(
        seller_user: @owner,
        event: @event,
        type: "adjustment",
        amount_minor: 1_000,
        currency: "ETB",
        available_at: Time.current,
        idempotency_key: "seller-payout-adjustment-#{sale.id}",
        description: "Additional seller proceeds",
        created_at: Time.current
      )

      result = BuildSellerPayout.call(
        seller: @owner,
        account: @account,
        currency: "ETB",
        idempotency_key: "seller-payout-after-reversal-#{sale.id}",
        cutoff_at: Time.current,
        at: Time.current
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal 1_000, result.value.amount_minor
    end

    test "a chargeback offsets proceeds before the seller requests immediate payout" do
      sale_result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)
      assert_predicate sale_result, :success?, sale_result.error&.message

      chargeback = FreezeChargebackProceeds.call(
        payment: @payment,
        actor: @manager,
        amount_minor: 500,
        idempotency_key: "seller-payout-chargeback-#{sale_result.value.id}"
      )
      assert_predicate chargeback, :success?, chargeback.error&.message
      assert_equal(-500, chargeback.value.amount_minor)

      result = BuildSellerPayout.call(
        seller: @owner,
        account: @account,
        currency: "ETB",
        idempotency_key: "seller-payout-after-chargeback-#{sale_result.value.id}",
        cutoff_at: Time.current,
        at: Time.current
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal sale_result.value.seller_proceeds_minor - 500, result.value.amount_minor
    end

    test "a cross-event chargeback is netted without debiting the negative event" do
      sale_result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)
      assert_predicate sale_result, :success?, sale_result.error&.message
      sale = sale_result.value

      chargeback = FreezeChargebackProceeds.call(
        payment: @payment,
        actor: @manager,
        amount_minor: sale.gross_amount_minor,
        idempotency_key: "seller-payout-full-chargeback-#{sale.id}"
      )
      assert_predicate chargeback, :success?, chargeback.error&.message

      other_event = events_events(:draft_concert)
      SellerLedgerEntry.create!(
        seller_user: @owner,
        event: other_event,
        type: "adjustment",
        amount_minor: 5_000,
        currency: "ETB",
        available_at: Time.current,
        idempotency_key: "seller-payout-after-chargeback-#{sale.id}",
        description: "Proceeds from another event",
        created_at: Time.current
      )

      built = BuildSellerPayout.call(
        seller: @owner,
        account: @account,
        currency: "ETB",
        idempotency_key: "seller-payout-full-chargeback-net-#{sale.id}",
        cutoff_at: Time.current,
        at: Time.current
      )
      assert_predicate built, :success?, built.error&.message
      assert_equal 5_000 - sale.marketplace_fee_minor, built.value.amount_minor

      settled = DispatchSellerPayout.call(
        payout: built.value,
        adapter: SuccessfulAdapter.new,
        at: Time.current
      )
      assert_predicate settled, :success?, settled.error&.message

      payout_entries = SellerLedgerEntry.where(seller_payout_id: built.value.id, type: "payout")
      assert_equal [ other_event.id ], payout_entries.pluck(:event_id)
      assert_equal(-built.value.amount_minor, payout_entries.sole.amount_minor)
      assert_equal(-sale.marketplace_fee_minor, SellerLedgerEntry.where(
        seller_user: @owner, event: @event
      ).sum(:amount_minor))
      assert_equal sale.marketplace_fee_minor, SellerLedgerEntry.where(
        seller_user: @owner, event: other_event
      ).sum(:amount_minor)
      assert_equal 0, SellerBalanceReport.call(seller: @owner, currency: "ETB").value.sole[:available_minor]
    end

    test "seller-wide payout nets events and attributes payout debits to source events" do
      sale_result = FulfillSale.call(listing: @listing, order: @order, payment: @payment)
      assert_predicate sale_result, :success?, sale_result.error&.message
      sale = sale_result.value
      other_event = events_events(:draft_concert)
      SellerLedgerEntry.create!(
        seller_user: @owner,
        event: other_event,
        type: "adjustment",
        amount_minor: 1_000,
        currency: "ETB",
        available_at: Time.current,
        idempotency_key: "seller-payout-cross-event-#{sale.id}",
        description: "Seller proceeds from another event",
        created_at: Time.current
      )

      built = BuildSellerPayout.call(
        seller: @owner,
        account: @account,
        currency: "ETB",
        idempotency_key: "seller-payout-across-events-#{sale.id}",
        cutoff_at: Time.current,
        at: Time.current
      )

      assert_predicate built, :success?, built.error&.message
      assert_equal sale.seller_proceeds_minor + 1_000, built.value.amount_minor

      settled = DispatchSellerPayout.call(
        payout: built.value,
        adapter: SuccessfulAdapter.new,
        at: Time.current
      )

      assert_predicate settled, :success?, settled.error&.message
      payout_entries = SellerLedgerEntry.where(seller_payout_id: built.value.id, type: "payout")
      assert_equal [ @event.id, other_event.id ].sort, payout_entries.pluck(:event_id).sort
      assert_equal(-sale.seller_proceeds_minor, payout_entries.find_by!(event_id: @event.id).amount_minor)
      assert_equal(-1_000, payout_entries.find_by!(event_id: other_event.id).amount_minor)
      assert_equal(-built.value.amount_minor, payout_entries.sum(:amount_minor))
      assert_equal 0, SellerBalanceReport.call(seller: @owner, currency: "ETB").value.sole[:available_minor]
    end

    test "seller-wide payout with cross-event negative balance attributes debits without over-debiting positive events" do
      other_event = events_events(:draft_concert)
      SellerLedgerEntry.create!(
        seller_user: @owner,
        event: other_event,
        type: "adjustment",
        amount_minor: -1_000,
        currency: "ETB",
        available_at: Time.current,
        idempotency_key: "seller-payout-negative-other-event-#{SecureRandom.hex(4)}",
        description: "Negative adjustment on other event",
        created_at: Time.current
      )

      SellerLedgerEntry.create!(
        seller_user: @owner,
        event: @event,
        type: "adjustment",
        amount_minor: 5_000,
        currency: "ETB",
        available_at: Time.current,
        idempotency_key: "seller-payout-positive-event-#{SecureRandom.hex(4)}",
        description: "Proceeds on primary event",
        created_at: Time.current
      )

      built = BuildSellerPayout.call(
        seller: @owner,
        account: @account,
        currency: "ETB",
        idempotency_key: "seller-payout-cross-event-negative-#{SecureRandom.hex(4)}",
        cutoff_at: Time.current,
        at: Time.current
      )

      assert_predicate built, :success?, built.error&.message
      assert_equal 4_000, built.value.amount_minor

      settled = DispatchSellerPayout.call(
        payout: built.value,
        adapter: SuccessfulAdapter.new,
        at: Time.current
      )

      assert_predicate settled, :success?, settled.error&.message
      payout_entries = SellerLedgerEntry.where(seller_payout_id: built.value.id, type: "payout")
      assert_equal [ @event.id ], payout_entries.pluck(:event_id)
      assert_equal(-4_000, payout_entries.sole.amount_minor)

      assert_equal 1_000, SellerLedgerEntry.where(seller_user: @owner, event: @event).sum(:amount_minor)
      assert_equal(-1_000, SellerLedgerEntry.where(seller_user: @owner, event: other_event).sum(:amount_minor))
      assert_equal 0, SellerBalanceReport.call(seller: @owner, currency: "ETB").value.sole[:available_minor]
    end

    test "seller-wide partial payout reserves negative facts and attributes debits up to positive net capacity" do
      SellerLedgerEntry.create!(
        seller_user: @owner,
        event: @event,
        type: "adjustment",
        amount_minor: 2_000,
        currency: "ETB",
        available_at: Time.current,
        idempotency_key: "seller-payout-partial-event1-pos-#{SecureRandom.hex(4)}",
        description: "Proceeds on event 1",
        created_at: Time.current
      )
      SellerLedgerEntry.create!(
        seller_user: @owner,
        event: @event,
        type: "adjustment",
        amount_minor: -500,
        currency: "ETB",
        available_at: Time.current,
        idempotency_key: "seller-payout-partial-event1-neg-#{SecureRandom.hex(4)}",
        description: "Fee on event 1",
        created_at: Time.current
      )

      other_event = events_events(:draft_concert)
      SellerLedgerEntry.create!(
        seller_user: @owner,
        event: other_event,
        type: "adjustment",
        amount_minor: 4_000,
        currency: "ETB",
        available_at: Time.current,
        idempotency_key: "seller-payout-partial-event2-pos-#{SecureRandom.hex(4)}",
        description: "Proceeds on event 2",
        created_at: Time.current
      )

      built = BuildSellerPayout.call(
        seller: @owner,
        account: @account,
        currency: "ETB",
        amount_minor: 4_000,
        idempotency_key: "seller-payout-partial-test-#{SecureRandom.hex(4)}",
        cutoff_at: Time.current,
        at: Time.current
      )

      assert_predicate built, :success?, built.error&.message
      assert_equal 4_000, built.value.amount_minor

      settled = DispatchSellerPayout.call(
        payout: built.value,
        adapter: SuccessfulAdapter.new,
        at: Time.current
      )

      assert_predicate settled, :success?, settled.error&.message
      payout_entries = SellerLedgerEntry.where(seller_payout_id: built.value.id, type: "payout")
      assert_equal({ @event.id => -1_500, other_event.id => -2_500 },
        payout_entries.pluck(:event_id, :amount_minor).to_h)
      assert_equal 0, SellerLedgerEntry.where(seller_user: @owner, event: @event).sum(:amount_minor)
      assert_equal 1_500, SellerLedgerEntry.where(seller_user: @owner, event: other_event).sum(:amount_minor)
      assert_equal(-4_000, payout_entries.sum(:amount_minor))
      assert_equal 1_500, SellerBalanceReport.call(seller: @owner, currency: "ETB").value.sole[:available_minor]
    end
  end
end
