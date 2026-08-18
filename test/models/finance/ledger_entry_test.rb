# frozen_string_literal: true

require "test_helper"

module Finance
  class LedgerEntryTest < ActiveSupport::TestCase
    include LedgerTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @organization = Organizations::Organization.find(@event.organization_id)
      @order = create_ledger_order
    end

    test "uses the business type column without STI" do
      assert_predicate Finance::LedgerEntry.inheritance_column, :blank?

      entry = Finance::LedgerEntry.new(type: "sale")

      assert_equal "sale", entry.type
    end

    test "requires the event primary organization and shared event references" do
      entry = build_entry
      assert_predicate entry, :valid?, entry.errors.full_messages

      eventless_entry = build_entry(event_id: nil)
      assert_not eventless_entry.valid?
      assert_includes eventless_entry.errors.attribute_names, :event

      entry.organization_id = Organizations::Organization.where.not(id: @organization.id).pick(:id)
      assert_not entry.valid?
      assert_includes entry.errors.attribute_names, :organization

      entry = build_entry(order_id: @order.id, payment_id: nil)
      assert_predicate entry, :valid?, entry.errors.full_messages

      entry.event_id = events_events(:draft_concert).id
      assert_not entry.valid?
      assert_includes entry.errors.attribute_names, :order

      entry = build_entry(order_id: @order.id, event_id: @order.event_id, currency: "USD")
      assert_not entry.valid?
      assert_includes entry.errors.attribute_names, :currency
    end

    test "validates currency, nonzero amounts, and type signs" do
      invalid_currency = build_entry(currency: "usd")
      invalid_amount = build_entry(amount_minor: 0)
      invalid_sale = build_entry(amount_minor: -1)
      invalid_fee = build_entry(type: "platform_fee", amount_minor: 1)
      invalid_type = build_entry(type: "unknown")

      [ invalid_currency, invalid_amount, invalid_sale, invalid_fee, invalid_type ].each do |entry|
        assert_not entry.valid?, entry.errors.full_messages
      end
    end

    test "enforces globally unique idempotency keys" do
      attributes = build_entry_attributes(idempotency_key: "ledger-duplicate-key")
      Finance::LedgerEntry.create!(attributes)

      duplicate = assert_raises(ActiveRecord::RecordInvalid) do
        Finance::LedgerEntry.create!(attributes)
      end

      assert_includes duplicate.record.errors.attribute_names, :idempotency_key
    end

    test "rejects normal updates and deletes" do
      entry = Finance::LedgerEntry.create!(build_entry_attributes)

      assert_raises(ActiveRecord::ReadOnlyRecord) { entry.update!(description: "changed") }
      assert_raises(ActiveRecord::ReadOnlyRecord) { entry.destroy! }
    end

    test "reversal evidence keeps the original currency and opposite amount" do
      entry = Finance::LedgerEntry.create!(build_entry_attributes)
      reversal = Finance::LedgerEntry.new(
        build_entry_attributes(
          type: "adjustment",
          amount_minor: -entry.amount_minor,
          reverses_entry_id: entry.id,
          idempotency_key: "ledger-reversal-#{SecureRandom.hex(8)}"
        )
      )

      assert_predicate reversal, :valid?, reversal.errors.full_messages

      reversal.currency = "USD"
      assert_not reversal.valid?
      assert_includes reversal.errors.attribute_names, :currency
    end

    private

    def build_entry(overrides = {})
      Finance::LedgerEntry.new(build_entry_attributes(overrides))
    end

    def build_entry_attributes(overrides = {})
      {
        organization_id: @organization.id,
        event_id: @event.id,
        order_id: nil,
        payment_id: nil,
        refund_id: nil,
        reverses_entry_id: nil,
        type: "sale",
        amount_minor: 10_000,
        currency: "ETB",
        available_at: 7.days.from_now,
        idempotency_key: "ledger-entry-#{SecureRandom.hex(8)}",
        description: "Ledger test entry",
        created_at: Time.current
      }.merge(overrides)
    end
  end
end
