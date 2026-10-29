# frozen_string_literal: true

require "test_helper"

module Orders
  module GiftPurchases
    class RevokeForEventTest < ActiveSupport::TestCase
      include Orders::GiftPurchaseTestHelpers

      test "revokes every ready gift in the event using preloaded gift rows" do
        setup_gift_purchase_context
        first_gift = @gift_purchase
        first_registration = @gift_registration
        setup_gift_purchase_context(recipient_phone: "0911000179")
        second_gift = @gift_purchase
        second_registration = @gift_registration
        [ first_registration, second_registration ].each do |registration|
          registration.update_columns(status: "cancelled", cancelled_at: Time.current)
        end

        result = RevokeForEvent.call(event: @gift_event)

        assert_predicate result, :success?, result.error&.message
        assert_equal 2, result.value
        assert_equal %w[revoked revoked], Orders::GiftPurchase.where(
          id: [ first_gift.id, second_gift.id ]
        ).order(:id).pluck(:status)
      end

      test "revokes a gift that is waiting for recipient consent when the event is cancelled" do
        setup_gift_purchase_context
        @gift_registration.update_columns(status: "confirmed", confirmed_at: Time.current)
        @gift_purchase.update!(status: "pending_recipient_consent")

        result = RevokeForEvent.call(event: @gift_event)

        assert_predicate result, :success?, result.error&.message
        assert_equal 1, result.value
        assert_equal "revoked", @gift_purchase.reload.status
      end

      test "locks only gift rows in the joined event revocation scan" do
        setup_gift_purchase_context
        sql_statements = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
          sql_statements << payload[:sql]
        end

        result = RevokeForEvent.call(event: @gift_event)

        assert_predicate result, :success?, result.error&.message
        lock_statement = sql_statements.find do |statement|
          statement.include?("orders_gift_purchases") && statement.include?("FOR UPDATE")
        end
        assert_match(/FOR UPDATE OF [\"]?orders_gift_purchases[\"]?/i, lock_statement)
      ensure
        ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
      end
    end
  end
end
