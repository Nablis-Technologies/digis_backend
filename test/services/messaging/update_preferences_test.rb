# frozen_string_literal: true

require "test_helper"

module Messaging
  class UpdatePreferencesTest < ActiveSupport::TestCase
    setup do
      @user = core_users(:attendee)
    end

    test "updates preferences and replays through the shared idempotency helper" do
      subject = -> do
        Messaging::UpdatePreferences.call(
          user: @user,
          preferences: [ { category: "transactional", channel: "email", enabled: false } ],
          idempotency_key: "preferences-replay"
        )
      end

      assert_idempotent(subject, counter: -> { Messaging::NotificationPreference.where(user: @user).count })
      assert_equal false, @user.notification_preferences.find_by!(category: "transactional", channel: "email").enabled
    end

    test "a changed request under the same idempotency key fails closed" do
      first = Messaging::UpdatePreferences.call(
        user: @user,
        preferences: [ { category: "transactional", channel: "email", enabled: false } ],
        idempotency_key: "preferences-conflict"
      )
      assert_predicate first, :success?

      conflict = Messaging::UpdatePreferences.call(
        user: @user,
        preferences: [ { category: "transactional", channel: "sms", enabled: false } ],
        idempotency_key: "preferences-conflict"
      )

      assert_predicate conflict, :failure?
      assert_equal "notification_idempotency_conflict", conflict.error.code
    end

    test "mandatory in-app delivery cannot be disabled" do
      result = Messaging::UpdatePreferences.call(
        user: @user,
        preferences: [ { category: "credential", channel: "in_app", enabled: false } ],
        idempotency_key: "mandatory-preference"
      )

      assert_predicate result, :failure?
      assert_equal "notification_preference_mandatory", result.error.code
    end
  end
end
