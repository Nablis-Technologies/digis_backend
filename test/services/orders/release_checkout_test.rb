# frozen_string_literal: true

require "test_helper"

module Orders
  class ReleaseCheckoutTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      @order = create_order
    end

    test "acquires checkout advisory lock before locking the order" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
        statements << payload[:sql]
      end

      result = ReleaseCheckout.call(order: @order)

      assert_predicate result, :success?, result.error&.message
      advisory_index = statements.index { |sql| sql.include?("pg_advisory_xact_lock") }
      order_lock_index = statements.index do |sql|
        sql.match?(/FROM\s+"orders_orders".*FOR UPDATE/i)
      end

      assert_not_nil advisory_index, "expected the shared checkout advisory lock"
      assert_not_nil order_lock_index, "expected an order row lock"
      assert_operator advisory_index, :<, order_lock_index
      assert_equal "expired", @order.reload.status
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
    end

    private

    def create_order
      Orders::Order.create!(
        event: @event,
        buyer_user: @buyer,
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 0,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 0,
        settlement_currency: "ETB",
        settlement_total_minor: 0,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 1.hour.from_now,
        expires_at: 1.hour.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
    end
  end
end
