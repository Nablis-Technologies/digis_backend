# frozen_string_literal: true

require "test_helper"

module Marketplace
  class SellerLedgerEntryTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @seller = core_users(:attendee)
    end

    test "business type does not enable STI" do
      assert_predicate SellerLedgerEntry.inheritance_column, :blank?
      assert_equal "resale_proceeds", build_entry(type: "resale_proceeds").type
    end

    test "rejects zero ledger entries" do
      entry = build_entry(amount_minor: 0)

      assert_not entry.valid?
      assert_includes entry.errors.attribute_names, :amount_minor
    end

    test "ledger entries are append-only" do
      entry = build_entry
      entry.save!

      assert_raises(ActiveRecord::ReadOnlyRecord) { entry.update!(amount_minor: 600) }
      assert_raises(ActiveRecord::ReadOnlyRecord) { entry.destroy! }
    end

    private

    def build_entry(overrides = {})
      SellerLedgerEntry.new(
        {
          seller_user: @seller,
          event: @event,
          type: "adjustment",
          amount_minor: 500,
          currency: "ETB",
          available_at: 1.day.from_now,
          idempotency_key: "seller-ledger-#{SecureRandom.hex(8)}",
          created_at: Time.current
        }.merge(overrides)
      )
    end
  end
end
