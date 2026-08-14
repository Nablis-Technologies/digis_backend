# frozen_string_literal: true

require "test_helper"

module Marketplace
  class DispatchSellerPayoutTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper
    include SellerPayoutTestHelpers

    class FakeAdapter < Marketplace::PayoutProviders::Adapter
      attr_reader :payout_requests, :verify_requests
      attr_accessor :payout_result, :verify_result, :balance

      def initialize
        @payout_requests = []
        @verify_requests = []
        @balance = { amount_minor: 100_000, currency: "ETB" }
        @payout_result = Marketplace::PayoutProviders::Result.success(
          provider_reference: "seller-payout-reference-1"
        )
        @verify_result = @payout_result
      end

      def tokenize_payout_account(**) = { account_token: "unused" }

      def verify_payout_account(**) = Marketplace::PayoutProviders::Result.success

      def payout(**request)
        @payout_requests << request
        payout_result
      end

      def verify_payout(**request)
        @verify_requests << request
        verify_result
      end

      def available_balance(**) = balance

      def capabilities = { payouts: { supported: true } }
    end

    setup do
      setup_seller_payout_context
      create_seller_ledger_entry(amount_minor: -1_000, type: "adjustment")
      create_seller_ledger_entry(amount_minor: 10_000, type: "adjustment")
      @build_result = build_seller_payout
      assert_predicate @build_result, :success?, @build_result.error&.message
      @payout = @build_result.value
      @adapter = FakeAdapter.new
    end

    test "commits processing before dispatch, consumes allocations, and records seller payout" do
      result = DispatchSellerPayout.call(payout: @payout, adapter: @adapter, at: @now)

      assert_predicate result, :success?, result.error&.message
      assert_equal "succeeded", @payout.reload.status
      assert_equal "seller-payout-reference-1", @payout.provider_reference
      assert_equal [ "consumed" ], @payout.seller_payout_allocations.reload.pluck(:status).uniq
      payout_entry = SellerLedgerEntry.find_by!(seller_payout_id: @payout.id)
      assert_equal(-@payout.amount_minor, payout_entry.amount_minor)
      assert_equal @event.id, payout_entry.event_id
      assert_equal 1, Core::AuditLog.where(
        auditable_type: SellerPayoutAccount.name,
        auditable_id: @account.id,
        action: "marketplace.seller_payout_account.used"
      ).count
      request = @adapter.payout_requests.fetch(0)
      assert_equal @account.account_token, request.fetch(:destination_token)
      assert_equal @payout.id, request.fetch(:payout_id)
      refute request.key?(:payment_id)
      refute request.key?(:original_payment_method)

      replay = DispatchSellerPayout.call(payout: @payout, adapter: @adapter, at: @now)

      assert_predicate replay, :success?, replay.error&.message
      assert_equal 1, @adapter.payout_requests.size
      assert_equal 1, SellerLedgerEntry.where(seller_payout_id: @payout.id).count
    end

    test "releases reserved allocations on provider failure" do
      @adapter.payout_result = Marketplace::PayoutProviders::Result.failure(failure_code: "declined")

      result = DispatchSellerPayout.call(payout: @payout, adapter: @adapter, at: @now)

      assert_predicate result, :success?, result.error&.message
      assert_equal "failed", @payout.reload.status
      assert_equal [ "released" ], @payout.seller_payout_allocations.reload.pluck(:status).uniq
      assert_empty SellerLedgerEntry.where(seller_payout_id: @payout.id)
    end

    test "leaves timeouts processing and reconciles without a blind retry" do
      @adapter.payout_result = Marketplace::PayoutProviders::Result.timeout(raw_status: "timeout")
      @adapter.verify_result = Marketplace::PayoutProviders::Result.success(
        provider_reference: "seller-reconciled-reference"
      )

      result = nil
      assert_enqueued_with(job: ReconcileSellerPayoutJob, args: [ @payout.id ]) do
        result = DispatchSellerPayout.call(payout: @payout, adapter: @adapter, at: @now)
      end

      assert_predicate result, :success?, result.error&.message
      assert_equal "processing", @payout.reload.status
      assert_equal 1, @adapter.payout_requests.size

      reconciled = ReconcileSellerPayout.call(payout: @payout, adapter: @adapter, at: @now)

      assert_predicate reconciled, :success?, reconciled.error&.message
      assert_equal "succeeded", @payout.reload.status
      assert_equal 1, @adapter.payout_requests.size
      assert_equal 1, @adapter.verify_requests.size
    end

    test "does not dispatch when provider liquidity cannot cover the payout" do
      @adapter.balance = { amount_minor: 1_000, currency: "ETB" }

      result = DispatchSellerPayout.call(payout: @payout, adapter: @adapter, at: @now)

      assert_predicate result, :failure?
      assert_equal "seller_payout_provider_reserve_breach", result.error.code
      assert_equal "pending", @payout.reload.status
      assert_empty @adapter.payout_requests
    end
  end
end
