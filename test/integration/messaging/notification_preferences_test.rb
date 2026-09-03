# frozen_string_literal: true

require "test_helper"

module Messaging
  class NotificationPreferencesTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    test "updates preferences with an idempotency key" do
      patch "/notification_preferences",
        params: {
          preferences: [ { category: "transactional", channel: "email", enabled: false } ]
        }.to_json,
        headers: user_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "preferences-api")

      assert_response :success
      preference = core_users(:attendee).notification_preferences.find_by!(
        category: "transactional", channel: "email"
      )
      assert_equal false, preference.enabled
      response_preference = JSON.parse(response.body).fetch("data").find do |row|
        row["category"] == "transactional" && row["channel"] == "email"
      end
      assert_equal preference.id, response_preference.fetch("id")
    end

    test "returns enabled defaults for preferences that have no stored row" do
      get "/notification_preferences", headers: user_headers, as: :json

      assert_response :success
      rows = JSON.parse(response.body).fetch("data")
      assert_equal Messaging::Notification::CATEGORIES.length * Messaging::NotificationDelivery::CHANNELS.length,
        rows.length
      assert rows.all? { |row| row.fetch("enabled") }
      assert_nil rows.find { |row| row["category"] == "transactional" && row["channel"] == "email" }.fetch("id")
    end

    test "missing idempotency key returns bad request" do
      patch "/notification_preferences",
        params: { preferences: [] }.to_json,
        headers: user_headers.merge("Content-Type" => "application/json")

      assert_response :bad_request
      assert_equal "missing_idempotency_key", JSON.parse(response.body).fetch("code")
    end

    test "mandatory in-app preference cannot be disabled" do
      patch "/notification_preferences",
        params: {
          preferences: [ { category: "credential", channel: "in_app", enabled: false } ]
        }.to_json,
        headers: user_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "mandatory-api")

      assert_response :unprocessable_entity
      assert_equal "notification_preference_mandatory", JSON.parse(response.body).fetch("code")
    end
  end
end
