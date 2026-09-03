# frozen_string_literal: true

require "test_helper"

module Messaging
  class NotificationPreferenceTest < ActiveSupport::TestCase
    test "preference schema is unique per user category and channel" do
      columns = Messaging::NotificationPreference.columns_hash

      assert_equal :uuid, columns.fetch("user_id").type
      assert_equal :boolean, columns.fetch("enabled").type

      indexes = Messaging::NotificationPreference.connection.indexes("messaging_notification_preferences")
      assert indexes.any? { |index| index.unique && index.columns == %w[user_id category channel] }
    end

    test "preference schema constrains categories and channels" do
      constraints = Messaging::NotificationPreference.connection
        .check_constraints("messaging_notification_preferences")

      assert constraints.any? { |constraint| constraint.name == "messaging_notification_preferences_category_check" }
      assert constraints.any? { |constraint| constraint.name == "messaging_notification_preferences_channel_check" }
    end
  end
end
