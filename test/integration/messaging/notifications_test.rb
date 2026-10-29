# frozen_string_literal: true

require "test_helper"

module Messaging
  class NotificationsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include MessagingTestHelpers
    include Ticketing::PackageWorkflowTestHelpers

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

    test "recipient inbox exposes a safe incoming-transfer notification from the outbox" do
      setup_package_workflow(admissions_per_unit: 1)
      initiated = Ticketing::Transfers::Initiate.call(
        ticket: @ticket,
        actor: @owner,
        phone: @recipient.phone,
        idempotency_key: "inbox-transfer-initiation"
      )
      assert_predicate initiated, :success?, initiated.error&.message
      assert_equal @recipient.id, initiated.value.transfer.to_user_id

      outbox_event = Core::OutboxEvent.find_by!(
        aggregate: initiated.value.transfer,
        event_type: "ticketing.ticket_transfer.initiated"
      )
      dispatched = Core::Outbox::Dispatch.call(event_id: outbox_event.id)
      assert_predicate dispatched, :success?, dispatched.error&.message

      recipient_token = Core::TokenService.issue(Core::TokenService.access_token_payload(@recipient))
      get "/notifications",
        headers: { "Authorization" => "Bearer #{recipient_token}" },
        as: :json

      assert_response :success
      incoming = response.parsed_body.fetch("data").find do |row|
        row.fetch("notification_type") == "transfer_incoming"
      end
      assert incoming
      assert_equal initiated.value.transfer.id, incoming.dig("data", "transfer_id")
      assert_equal @event.id, incoming.dig("data", "event_id")
      assert_equal [
        "event_id", "event_title", "expires_at", "ticket_id", "ticket_label", "transfer_id"
      ], incoming.fetch("data").keys.sort

      other_user = core_users(:support)
      other_user_token = Core::TokenService.issue(Core::TokenService.access_token_payload(other_user))
      get "/notifications",
        headers: { "Authorization" => "Bearer #{other_user_token}" },
        as: :json

      assert_response :success
      other_user_has_transfer = response.parsed_body.fetch("data").any? do |row|
        row.fetch("notification_type") == "transfer_incoming"
      end
      refute other_user_has_transfer, response.parsed_body.inspect
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
