# frozen_string_literal: true

module Marketplace
  module SellerPayoutTestHelpers
    def setup_seller_payout_context
      @now = Time.utc(2026, 8, 13, 12, 0, 0)
      @seller = core_users(:attendee)
      @event = events_events(:ready_listing)
      @event.update_columns(status: "completed", completed_at: @now - 8.days)
      @account = create_payout_account(status: "verified", verified_at: @now)
    end

    def create_payout_account(status: "pending_verification", verified_at: nil,
      account_number: "1000000000001")
      number = account_number
      SellerPayoutAccount.create!(
        user: @seller,
        type: "bank",
        provider: "chapa",
        bank_slug: "cbe",
        account_number: number,
        account_number_digest: Core::PayoutAccountDigest.call(
          namespace: @seller.id, account_number: number
        ),
        account_label: "Seller bank account",
        holder_name: "Seller Holder",
        status:,
        verification_source: status == "verified" ? "test_fixture" : nil,
        verified_at:,
        is_default: false
      )
    end

    def create_seller_ledger_entry(amount_minor:, type: "adjustment", currency: "ETB",
      available_at: @now - 1.day, event: @event, created_at: available_at)
      SellerLedgerEntry.create!(
        seller_user: @seller,
        event:,
        type:,
        amount_minor:,
        currency:,
        available_at:,
        idempotency_key: "seller-ledger-test-#{SecureRandom.hex(8)}",
        description: "Seller payout test fact",
        created_at:
      )
    end

    def build_seller_payout(idempotency_key: "seller-payout-build-1", amount_minor: nil,
      event: @event, cutoff_at: @now, at: @now, account: @account)
      BuildSellerPayout.call(
        seller: @seller,
        account:,
        event:,
        currency: "ETB",
        idempotency_key:,
        amount_minor:,
        cutoff_at:,
        at:
      )
    end
  end
end
