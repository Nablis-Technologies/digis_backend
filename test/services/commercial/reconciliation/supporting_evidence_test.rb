# frozen_string_literal: true

require "test_helper"

module Commercial
  module Reconciliation
    class SupportingEvidenceTest < ActiveSupport::TestCase
      include Commercial::GovernanceTestHelpers
      include Commercial::SubsidyReservationTestHelpers

      test "reports subsidy usage and budget exhaustion without changing terminal evidence" do
        setup_subsidy_reservation_context(limit_minor: 1_000, subsidy_minor: 500)
        held = Commercial::Subsidies::Hold.call(
          budget: @budget,
          order: @order,
          amount_minor: 500,
          currency: "ETB",
          expires_at: 10.minutes.from_now,
          idempotency_key: "task12-supporting-hold"
        )
        assert_predicate held, :success?, held.error&.message
        committed = Commercial::Subsidies::Commit.call(reservation: held.value)
        assert_predicate committed, :success?, committed.error&.message

        @order.update_columns(subsidy_minor: 400, total_minor: 9_600, settlement_total_minor: 9_600)
        @order.update_columns(status: "paid", paid_at: Time.current)
        @budget.reload.update_columns(consumed_minor: 1_000)
        assert_equal [ 1_000, 500 ], [ @budget.reload.consumed_minor, committed.value.reload.amount_minor ]

        result = Commercial::Reconciliation::Run.call(at: Time.current)

        assert_predicate result, :success?, result.error&.message
        kinds = result.value.fetch(:mismatches).map { |row| row.fetch(:kind) }
        assert_includes kinds, "subsidy_usage_mismatch"
        assert_includes kinds, "subsidy_budget_mismatch"
        assert Core::AuditLog.where(action: "commercial.operational_alert")
          .where("metadata ->> 'kind' = 'budget_exhausted'").exists?
        assert_equal "committed", committed.value.reload.status
        assert_equal 500, committed.value.amount_minor
      end

      test "alerts before an explicit-acceptance grandfather period expires" do
        version = create_simulatable_version(
          code: "task12_grandfather",
          attributes: {
            acceptance_policy: "explicit",
            effective_from: 2.days.ago,
            grandfather_until: 1.day.from_now
          }
        )
        version.update!(
          status: "active",
          activated_by: core_users(:super_admin),
          activated_at: 2.days.ago
        )

        result = Commercial::Reconciliation::Run.call(at: Time.current)

        assert_predicate result, :success?, result.error&.message
        assert_equal "grandfather_expiring", Core::AuditLog.where(
          action: "commercial.operational_alert"
        ).sole.metadata.fetch("kind")
      end
    end

    class FinanceEvidenceTest < ActiveSupport::TestCase
      include Finance::LedgerTestHelpers

      test "reports payout allocation drift without changing the payout or ledger" do
        payout = nil
        entry = nil
        create_ledger_order(status: "fulfilled", settlement_total_minor: 10_000) do |draft_order|
          event = draft_order.event
          entry = Finance::LedgerEntry.create!(
            organization_id: event.organization_id,
            event_id: event.id,
            order_id: draft_order.id,
            type: "sale",
            amount_minor: 10_000,
            currency: "ETB",
            available_at: Time.current,
            idempotency_key: "task12-ledger-entry-#{SecureRandom.hex(4)}",
            description: "Task 12 test sale",
            created_at: Time.current
          )
          payout_account = Finance::PayoutAccount.create!(
            organization: event.organization,
            type: "bank",
            provider: "chapa",
            bank_code: 128,
            account_number: "1000000000001",
            account_name: "Task 12 Organizer",
            account_number_digest: Core::KeyedDigest.digest(
              namespace: event.organization.id, value: "1000000000001"
            ),
            status: "verified",
            verification_source: "test_fixture",
            verified_at: Time.current,
            is_default: true
          )
          payout = Finance::Payout.create!(
            organization_id: event.organization_id,
            payout_account: payout_account,
            currency: "ETB",
            status: "pending",
            amount_minor: 10_000,
            idempotency_key: "task12-payout-#{SecureRandom.hex(4)}",
            requested_at: Time.current
          )
          payout.allocations.create!(ledger_entry: entry, amount_minor: 9_000, status: "reserved")
        end

        result = Commercial::Reconciliation::Run.call

        assert_predicate result, :success?, result.error&.message
        assert_includes result.value.fetch(:mismatches).map { |row| row.fetch(:kind) }, "payout_allocation_mismatch"
        assert_equal 10_000, payout.reload.amount_minor
        assert_equal 9_000, payout.allocations.sole.amount_minor
        assert_equal 10_000, entry.reload.amount_minor
      end
    end
  end
end
