# frozen_string_literal: true

require "test_helper"

module Messaging
  class NotificationTest < ActiveSupport::TestCase
    test "notification schema has recipient and retention boundaries" do
      columns = Messaging::Notification.columns_hash

      assert_equal :uuid, columns.fetch("user_id").type
      assert_equal :jsonb, columns.fetch("data").type
      assert_equal :uuid, columns.fetch("retention_policy_id").type
      assert_equal :string, columns.fetch("projection_digest").type
      assert_includes Core::DataRetentionPolicy::CATEGORIES, "messaging_notification"

      indexes = Messaging::Notification.connection.indexes("messaging_notifications")
      assert indexes.any? { |index| index.unique && index.columns == %w[user_id dedupe_key] }
    end

    test "notification data is object-shaped and categories are constrained" do
      assert Messaging::Notification.connection.check_constraints("messaging_notifications")
        .any? { |constraint| constraint.name == "messaging_notifications_data_object_check" }
      assert Messaging::Notification.connection.check_constraints("messaging_notifications")
        .any? { |constraint| constraint.name == "messaging_notifications_category_check" }
      assert Messaging::Notification.connection.check_constraints("messaging_notifications")
        .any? { |constraint| constraint.name == "messaging_notifications_projection_digest_check" }
    end
  end
end
