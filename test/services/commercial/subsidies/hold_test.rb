# frozen_string_literal: true

require "test_helper"

module Commercial
  module Subsidies
    class HoldTest < ActiveSupport::TestCase
      include Commercial::SubsidyReservationTestHelpers

      setup do
        setup_subsidy_reservation_context
        @expires_at = 10.minutes.from_now.change(usec: 0)
      end

      test "holds budget capacity and records request evidence" do
        result = hold

        assert_predicate result, :success?, result.error&.message
        reservation = result.value.reload
        assert reservation.held?
        assert_equal 500, @budget.reload.reserved_minor
        assert_equal 500, @budget.remaining_minor
        assert_equal 64, reservation.idempotency_key_digest.length
        assert_equal 64, reservation.request_fingerprint.length
        assert Core::AuditLog.exists?(
          action: "commercial.subsidy_reservation.held",
          auditable_type: reservation.class.name,
          auditable_id: reservation.id
        )
      end

      test "identical replay returns the original reservation without double holding" do
        subject = -> { hold }

        assert_idempotent(subject, counter: -> { SubsidyReservation.count })
        assert_equal 1, SubsidyReservation.count
        assert_equal 500, @budget.reload.reserved_minor
      end

      test "reusing an idempotency key with different request data conflicts" do
        first = hold
        conflict = hold(amount_minor: 400)

        assert_predicate first, :success?, first.error&.message
        assert_predicate conflict, :failure?
        assert_equal "idempotency_conflict", conflict.error.code
        assert_equal 1, SubsidyReservation.count
        assert_equal 500, @budget.reload.reserved_minor
      end

      test "rejects a hold that would exceed the hard budget" do
        result = hold(amount_minor: 1_001)

        assert_predicate result, :failure?
        assert_equal "subsidy_budget_exhausted", result.error.code
        assert_empty SubsidyReservation.all
        assert_equal 0, @budget.reload.reserved_minor
      end

      test "rejects mismatched currency, expired holds, and inactive orders" do
        currency_result = hold(currency: "USD")
        expired_result = hold(idempotency_key: "expired-hold", expires_at: 1.minute.ago)
        @order.update!(status: "expired", closed_reason: "checkout_expired")
        closed_result = hold(idempotency_key: "closed-hold")

        assert_equal "subsidy_currency_mismatch", currency_result.error.code
        assert_equal "subsidy_expiry_invalid", expired_result.error.code
        assert_equal "subsidy_order_not_active", closed_result.error.code
        assert_equal 0, SubsidyReservation.count
      end

      test "does not allow a second active reservation for the same order and budget" do
        first = hold
        second = hold(idempotency_key: "different-hold")

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :failure?
        assert_equal "subsidy_reservation_exists", second.error.code
        assert_equal 1, SubsidyReservation.count
        assert_equal 500, @budget.reload.reserved_minor
      end

      private

      def hold(amount_minor: 500, currency: "ETB", idempotency_key: "subsidy-hold", expires_at: @expires_at)
        Commercial::Subsidies::Hold.call(
          budget: @budget,
          order: @order,
          amount_minor:,
          currency:,
          expires_at:,
          idempotency_key:
        )
      end
    end

    class HoldConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      include Commercial::SubsidyReservationTestHelpers

      setup do
        setup_subsidy_reservation_context(limit_minor: 500, subsidy_minor: 500)
        @other_order = create_order(buyer: core_users(:support), subsidy_minor: 500)
        @expires_at = 10.minutes.from_now.change(usec: 0)
      end

      teardown do
        cleanup_test_records
      end

      test "two concurrent last-unit holds produce exactly one success" do
        ready = Queue.new
        start = Queue.new
        workers = [ @order, @other_order ].each_with_index.map do |order, index|
          Thread.new do
            Commercial::ApplicationRecord.connection_pool.with_connection do
              ready << true
              start.pop
              Commercial::Subsidies::Hold.call(
                budget: Commercial::SubsidyBudget.find(@budget.id),
                order: Orders::Order.find(order.id),
                amount_minor: 500,
                currency: "ETB",
                expires_at: @expires_at,
                idempotency_key: "concurrent-hold-#{index}"
              )
            end
          end
        end

        workers.length.times { ready.pop }
        workers.length.times { start << true }
        results = workers.map(&:value)

        assert_equal 1, results.count(&:success?)
        assert_equal 1, results.count(&:failure?)
        assert_equal "subsidy_budget_exhausted", results.find(&:failure?).error.code
        assert_equal 500, @budget.reload.reserved_minor
        assert_equal 1, SubsidyReservation.where(subsidy_budget_id: @budget.id).count
      end

      private

      def cleanup_test_records
        return unless @budget

        if defined?(Commercial::SubsidyReservation)
          reservation_ids = Commercial::SubsidyReservation.where(subsidy_budget_id: @budget.id).pluck(:id)
          Core::OutboxEvent.where(aggregate_type: "Commercial::SubsidyReservation", aggregate_id: reservation_ids).delete_all
          Core::AuditLog.where(auditable_type: "Commercial::SubsidyReservation", auditable_id: reservation_ids).delete_all
          Commercial::SubsidyReservation.where(id: reservation_ids).delete_all
        end
        Orders::Order.where(id: [ @order&.id, @other_order&.id ]).delete_all
        Commercial::SubsidyBudget.where(id: @budget.id).delete_all
      end
    end
  end
end
