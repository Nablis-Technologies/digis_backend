# frozen_string_literal: true

require "test_helper"

module Messaging
  class NotificationDeliveryTest < ActiveSupport::TestCase
    test "delivery schema has channel, status, retry, and idempotency boundaries" do
      columns = Messaging::NotificationDelivery.columns_hash

      assert_equal :uuid, columns.fetch("notification_id").type
      assert_equal :integer, columns.fetch("attempts").type
      assert_equal :string, columns.fetch("idempotency_key_digest").type
      assert_equal :datetime, columns.fetch("enqueue_claimed_at").type

      indexes = Messaging::NotificationDelivery.connection.indexes("messaging_notification_deliveries")
      assert indexes.any? { |index| index.unique && index.columns == %w[notification_id channel] }
    end

    test "delivery schema constrains channel and status" do
      constraints = Messaging::NotificationDelivery.connection
        .check_constraints("messaging_notification_deliveries")

      assert constraints.any? { |constraint| constraint.name == "messaging_notification_deliveries_channel_check" }
      assert constraints.any? { |constraint| constraint.name == "messaging_notification_deliveries_status_check" }
    end
  end
end
