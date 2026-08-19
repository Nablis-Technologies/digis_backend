# frozen_string_literal: true

require "test_helper"

module Finance
  class ConcurrentPayoutBuildTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    include PayoutTestHelpers

    setup do
      setup_payout_context
      @event.update_columns(completed_at: @now - 8.days)
      create_payout_entry(type: "sale", amount_minor: 10_000)
    end

    teardown do
      # This spec needs committed rows visible to two connections. Reset only
      # its test-owned rows afterward. The ledger is append-only in production,
      # so the teardown temporarily disables only its immutability trigger while
      # deleting this unique test scope and always restores it.
      connection = Finance::ApplicationRecord.connection
      connection.execute(
        "ALTER TABLE finance_ledger_entries DISABLE TRIGGER trg_finance_ledger_entry_immutable"
      )
      begin
        Finance::ApplicationRecord.transaction do
          payout_ids = Finance::Payout.where(organization_id: @organization.id).select(:id)
          Finance::Payout.where(id: payout_ids).update_all(status: "failed", failure_code: "test_cleanup")
          Finance::PayoutAllocation.where(payout_id: payout_ids).delete_all
          Finance::Payout.where(organization_id: @organization.id).delete_all
          Finance::LedgerEntry.where(organization_id: @organization.id).delete_all
          Events::Event.where(id: @event.id).delete_all
          Organizations::Organization.where(id: @organization.id).delete_all
        end
      ensure
        connection.execute(
          "ALTER TABLE finance_ledger_entries ENABLE TRIGGER trg_finance_ledger_entry_immutable"
        )
      end
    end

    test "concurrent builders reserve a ledger fact at most once" do
      race = run_database_race do |index|
        Finance::BuildPayout.call(
          organization: Organizations::Organization.find(@organization.id), currency: "ETB",
          idempotency_key: "concurrent-payout-#{index}", cutoff_at: @now, at: @now
        )
      end
      results = race.results

      assert_empty race.errors, race.errors.inspect
      assert_equal 1, results.count(&:success?), results.map { |result| [ result.success?, result.error&.code ] }.inspect
      assert_equal 1, results.count(&:failure?), results.map { |result| [ result.success?, result.error&.code ] }.inspect
      assert_equal 1, Finance::Payout.where(organization_id: @organization.id, currency: "ETB").count
      assert_equal 1, Finance::PayoutAllocation.joins(:payout)
        .where(finance_payouts: { organization_id: @organization.id, currency: "ETB" }).count
    end
  end
end
