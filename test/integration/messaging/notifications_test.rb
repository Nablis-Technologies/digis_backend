# frozen_string_literal: true

require "test_helper"

module Messaging
  class NotificationsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include MessagingTestHelpers

    setup do
      create_messaging_policy
      @user = core_users(:attendee)
      @notification = create_messaging_notification(user: @user, type: "schedule_changed")
      create_messaging_delivery(notification: @notification)
    end

    test "lists only the authenticated user's visible notifications" do
      get "/notifications", headers: user_headers, as: :json

      assert_response :success
      body = JSON.parse(response.body)
      assert_equal [ @notification.id ], body.fetch("data").map { |row| row.fetch("id") }
      refute body.fetch("data").first.key?("dedupe_key")
      delivery = body.fetch("data").first.fetch("deliveries").first
      refute delivery.key?("provider_message_id")
      refute delivery.key?("idempotency_key_digest")
    end

    test "another user cannot read the notification" do
      get "/notifications/#{@notification.id}", headers: owner_headers, as: :json

      assert_response :not_found
      assert_equal "notification_not_found", JSON.parse(response.body).fetch("code")
    end

    test "mark read is a safe repeated state set" do
      post "/notifications/#{@notification.id}/read", headers: user_headers, as: :json
      assert_response :success
      first_read_at = @notification.reload.read_at

      post "/notifications/#{@notification.id}/read", headers: user_headers, as: :json

      assert_response :success
      assert_equal first_read_at, @notification.reload.read_at
    end
  end
end
