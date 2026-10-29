# frozen_string_literal: true

require "test_helper"

module Finance
  class DispatchPayoutTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include PayoutTestHelpers

    class FakePayoutAdapter
      attr_reader :payout_calls, :verify_calls, :payout_requests
      attr_accessor :balance, :payout_result, :verify_result

      def initialize(balance: { amount_minor: 20_000, currency: "ETB" })
        @balance = balance
        @payout_calls = 0
        @verify_calls = 0
        @payout_requests = []
        @payout_result = Finance::PayoutProviders::Result.success(provider_reference: "provider-payout-1")
        @verify_result = @payout_result
      end

      def payout(**request)
        @payout_calls += 1
        payout_requests << request
        payout_result
      end

      def verify_payout(**)
        @verify_calls += 1
        verify_result
      end

      def available_balance(**)
        balance
      end

      def capabilities = { payouts: { supported: true } }
    end

    setup do
      setup_payout_context
      @event.update_columns(completed_at: @now - 8.days)
      create_payout_entry(type: "sale", amount_minor: 10_000)
      create_payout_entry(type: "sale", amount_minor: 10_000)
      @build_result = build_payout(amount_minor: 10_000)
      assert_predicate @build_result, :success?, @build_result.error&.message
      @payout = @build_result.value
      @payout.update!(provider: "chapa")
      @adapter = FakePayoutAdapter.new
      create_reserve_policy(target_minor: 2_000)
    end

    test "rechecks reserve, consumes allocations, and appends one payout ledger row on success" do
      result = Finance::DispatchPayout.call(payout: @payout, adapter: @adapter, at: @now)

      assert_predicate result, :success?, result.error&.message
      assert_equal "paid", @payout.reload.status
      assert_equal "provider-payout-1", @payout.provider_reference
      assert_equal [ "consumed" ], @payout.allocations.reload.pluck(:status).uniq
      payout_entry = Finance::LedgerEntry.find_by!(idempotency_key: "finance-payout-#{@payout.id}")
      assert_equal(-@payout.amount_minor, payout_entry.amount_minor)
      assert_equal 1, Finance::LedgerEntry.where(idempotency_key: "finance-payout-#{@payout.id}").count
      assert_equal "1000000000001", @adapter.payout_requests.sole.fetch(:account_number)
      assert_equal "cbe", @adapter.payout_requests.sole.fetch(:bank_slug)

      second = Finance::DispatchPayout.call(payout: @payout, adapter: @adapter, at: @now)
      assert_predicate second, :success?, second.error&.message
      assert_equal 1, @adapter.payout_calls
    end

    test "does not dispatch when provider cash would breach the reserve target" do
      @adapter.balance = { amount_minor: 11_000, currency: "ETB" }

      result = Finance::DispatchPayout.call(payout: @payout, adapter: @adapter, at: @now)

      assert_predicate result, :failure?
      assert_equal "provider_reserve_breach", result.error.code
      assert_equal "pending", @payout.reload.status
      assert_equal [ "reserved" ], @payout.allocations.reload.pluck(:status).uniq
      assert_equal 0, @adapter.payout_calls
    end

    test "does not dispatch through a suspended payout destination" do
      @payout.payout_account.update!(
        status: "suspended", is_default: false,
        verification_source: nil, verified_at: nil
      )

      result = Finance::DispatchPayout.call(payout: @payout, adapter: @adapter, at: @now)

      assert_predicate result, :failure?
      assert_equal "payout_account_required", result.error.code
      assert_equal 0, @adapter.payout_calls
    end

    test "allows a zero reserve target when provider cash covers the payout" do
      @payout.provider = "zero-target"
      @payout.save!
      @adapter.balance = { amount_minor: @payout.amount_minor, currency: "ETB" }
      create_reserve_policy(provider: "zero-target", target_minor: 0)

      result = Finance::DispatchPayout.call(payout: @payout, adapter: @adapter, at: @now)

      assert_predicate result, :success?, result.error&.message
      assert_equal "paid", @payout.reload.status
    end

    test "requires an audited treasury approval when provider balance is unavailable" do
      @adapter.balance = nil

      result = Finance::DispatchPayout.call(payout: @payout, adapter: @adapter, at: @now)

      assert_predicate result, :failure?
      assert_equal "treasury_approval_required", result.error.code
      assert_equal "pending", @payout.reload.status

      approval = @payout.record_audit!(
        "finance.payout.no_balance_api_approved",
        actor: core_users(:super_admin),
        audit_key: "finance-payout-approval-#{@payout.id}"
      )
      result = Finance::DispatchPayout.call(
        payout: @payout, adapter: @adapter, treasury_approval: approval, at: @now
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal "paid", @payout.reload.status
    end

    test "treats an unsupported balance API as unavailable" do
      @adapter.define_singleton_method(:available_balance) do |**|
        raise NotImplementedError
      end

      result = Finance::DispatchPayout.call(payout: @payout, adapter: @adapter, at: @now)

      assert_predicate result, :failure?
      assert_equal "treasury_approval_required", result.error.code
      assert_equal "pending", @payout.reload.status
      assert_equal 0, @adapter.payout_calls
    end

    test "releases reserved allocations on provider failure or cancellation" do
      Prosopite.pause do
        %i[failure cancelled].each do |outcome|
          payout = build_payout(idempotency_key: "payout-#{outcome}", amount_minor: 10_000).value
          payout.update!(provider: "chapa")
          adapter = FakePayoutAdapter.new
          adapter.payout_result = Finance::PayoutProviders::Result.public_send(outcome, failure_code: outcome.to_s)

          result = Finance::DispatchPayout.call(payout:, adapter:, at: @now)

          assert_predicate result, :success?, result.error&.message
          expected_status = outcome == :failure ? "failed" : outcome.to_s
          assert_equal expected_status, payout.reload.status
          assert_equal [ "released" ], payout.allocations.reload.pluck(:status).uniq
          assert_empty Finance::LedgerEntry.where(idempotency_key: "finance-payout-#{payout.id}")
        end
      end
    end

    test "leaves a timeout processing and reconciles it without a blind provider retry" do
      @adapter.payout_result = Finance::PayoutProviders::Result.timeout(raw_status: "timeout")
      @adapter.verify_result = Finance::PayoutProviders::Result.success(provider_reference: "reconciled-ref")

      result = nil
      assert_enqueued_with(job: Finance::ReconcilePayoutJob, args: [ @payout.id ]) do
        result = Finance::DispatchPayout.call(payout: @payout, adapter: @adapter, at: @now)
      end

      assert_predicate result, :success?, result.error&.message
      assert_equal "processing", @payout.reload.status
      assert_equal 1, @adapter.payout_calls

      reconciled = Finance::ReconcilePayout.call(payout: @payout, adapter: @adapter, at: @now)

      assert_predicate reconciled, :success?, reconciled.error&.message
      assert_equal "paid", @payout.reload.status
      assert_equal 1, @adapter.payout_calls
      assert_equal 1, @adapter.verify_calls
      assert_equal 1, Finance::LedgerEntry.where(idempotency_key: "finance-payout-#{@payout.id}").count
    end
  end
end
