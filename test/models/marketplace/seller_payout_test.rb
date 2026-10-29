# frozen_string_literal: true

require "test_helper"

module Marketplace
  class SellerPayoutTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @seller = core_users(:attendee)
      @account = SellerPayoutAccount.create!(
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: "1000000000015",
        account_number_digest: Core::PayoutAccountDigest.call(
          namespace: @seller.id, account_number: "1000000000015"
        ),
        holder_name: "Seller Holder",
        status: "pending_verification"
      )
    end

    test "business account type does not enable STI" do
      assert_predicate SellerPayoutAccount.inheritance_column, :blank?
      assert_equal "bank", @account.type
    end

    test "rejects payouts to an unverified account" do
      payout = build_payout

      assert_not payout.valid?
      assert_includes payout.errors.attribute_names, :seller_payout_account
    end

    test "database rejects allocation beyond the ledger amount" do
      @account.update!(status: "verified", verification_source: "test_fixture", verified_at: Time.current)
      payout = build_payout(amount_minor: 600).tap(&:save!)
      ledger_entry = SellerLedgerEntry.create!(
        seller_user: @seller,
        event: @event,
        type: "adjustment",
        amount_minor: 500,
        currency: "ETB",
        available_at: 1.day.from_now,
        idempotency_key: "seller-ledger-#{SecureRandom.hex(8)}",
        created_at: Time.current
      )
      SellerPayoutAllocation.create!(
        payout:,
        seller_ledger_entry: ledger_entry,
        amount_minor: 400,
        status: "reserved"
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        SellerPayoutAllocation.create!(
          payout:,
          seller_ledger_entry: ledger_entry,
          amount_minor: 200,
          status: "reserved"
        )
      end
    end

    private

    def build_payout(overrides = {})
      SellerPayout.new(
        {
          seller_user: @seller,
          seller_payout_account: @account,
          provider: "chapa",
          amount_minor: 500,
          currency: "ETB",
          status: "pending",
          idempotency_key: "seller-payout-#{SecureRandom.hex(8)}",
          requested_at: Time.current
        }.merge(overrides)
      )
    end
  end
end
