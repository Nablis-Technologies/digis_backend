# frozen_string_literal: true

require "test_helper"

module Finance
  class BuildPayoutTest < ActiveSupport::TestCase
    include PayoutTestHelpers

    setup do
      setup_payout_context
      @event.update_columns(completed_at: @now - 7.days)
    end

    test "requires event completion and the default seven-day buffer" do
      @event.update_columns(completed_at: @now - 6.days)
      entry = create_payout_entry(type: "sale", amount_minor: 10_000)

      result = build_payout

      assert_predicate result, :failure?
      assert_equal "payout_not_matured", result.error.code
      assert_equal entry.attributes.slice("amount_minor", "available_at"),
        entry.reload.attributes.slice("amount_minor", "available_at")

      @event.update_columns(completed_at: @now - 7.days)
      result = build_payout(idempotency_key: "payout-build-matured")

      assert_predicate result, :success?, result.error&.message
      assert_equal 10_000, result.value.amount_minor
    end

    test "postponed, cancelled, and other non-completed events cannot release sales" do
      entry = create_payout_entry(type: "sale", amount_minor: 10_000)

      %w[draft published cancelled].each do |status|
        @event.update_columns(status:, completed_at: nil)

        result = Prosopite.pause { build_payout(idempotency_key: "payout-#{status}") }

        assert_predicate result, :failure?
        assert_equal "payout_not_matured", result.error.code
      end

      event_date = @event.event_dates.create!(
        starts_at: @now - 2.days,
        ends_at: @now - 1.day,
        status: "postponed"
      )
      @event.update_columns(status: "published", completed_at: nil)

      result = Prosopite.pause { build_payout(idempotency_key: "payout-postponed-date") }

      assert_predicate result, :failure?
      assert_equal "payout_not_matured", result.error.code
      assert_equal "postponed", event_date.reload.status
      assert_equal 10_000, entry.reload.amount_minor
    end

    test "includes every available negative before positive earnings" do
      @event.update_columns(status: "completed", completed_at: @now - 8.days)
      sale = create_payout_entry(type: "sale", amount_minor: 10_000)
      fee = create_payout_entry(type: "platform_fee", amount_minor: -1_000)
      refund = create_payout_entry(type: "refund", amount_minor: -2_000)
      create_payout_entry(type: "chargeback", amount_minor: -500, available_at: @now + 1.hour)

      result = build_payout

      assert_predicate result, :success?, result.error&.message
      payout = result.value
      assert_equal 7_000, payout.amount_minor
      assert_equal [ fee.id, refund.id, sale.id ],
        payout.allocations.order(:created_at, :id).pluck(:ledger_entry_id)
      assert_equal [ -1_000, -2_000, 10_000 ],
        payout.allocations.order(:created_at, :id).pluck(:amount_minor)
    end

    test "keeps payout rows within one organization and currency" do
      @event.update_columns(status: "completed", completed_at: @now - 8.days)
      sale = create_payout_entry(type: "sale", amount_minor: 10_000)
      foreign_event = events_events(:draft_concert)
      foreign_entry = create_payout_entry(
        type: "sale", amount_minor: 99_000, event: foreign_event,
        organization: foreign_event.organization
      )
      usd_entry = create_payout_entry(type: "sale", amount_minor: 88_000, currency: "USD")

      result = build_payout

      assert_predicate result, :success?, result.error&.message
      assert_equal [ sale.id ], result.value.allocations.pluck(:ledger_entry_id)
      assert_not_includes result.value.allocations.pluck(:ledger_entry_id), foreign_entry.id
      assert_not_includes result.value.allocations.pluck(:ledger_entry_id), usd_entry.id
    end

    test "supports a partial payout while preserving negative-first allocation" do
      @event.update_columns(status: "completed", completed_at: @now - 8.days)
      fee = create_payout_entry(type: "platform_fee", amount_minor: -2_000)
      sale = create_payout_entry(type: "sale", amount_minor: 10_000)

      result = build_payout(amount_minor: 4_000)

      assert_predicate result, :success?, result.error&.message
      assert_equal 4_000, result.value.amount_minor
      assert_equal [ fee.id, sale.id ], result.value.allocations.order(:created_at, :id).pluck(:ledger_entry_id)
      assert_equal [ -2_000, 6_000 ], result.value.allocations.order(:created_at, :id).pluck(:amount_minor)
    end

    test "does not mutate the immutable ledger while a payout is ineligible" do
      @event.update_columns(status: "published", completed_at: nil)
      entry = create_payout_entry(type: "sale", amount_minor: 10_000)
      snapshot = entry.attributes.slice("amount_minor", "available_at", "idempotency_key")

      result = build_payout

      assert_predicate result, :failure?
      assert_equal snapshot, entry.reload.attributes.slice("amount_minor", "available_at", "idempotency_key")
      assert_empty Finance::PayoutAllocation.where(ledger_entry_id: entry.id)
    end
  end
end
