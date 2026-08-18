# frozen_string_literal: true

require "test_helper"

module Events
  class EventCancellationsIntegrationTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    def setup
      @event = events_events(:ready_listing)
    end

    def payload
      { cancellation: { internal_note: "internal", attendee_reason: "postponed" } }
    end

    def url
      "/events/#{@event.id}/event_cancellations"
    end

    test "owner can initiate a cancellation" do
      assert_difference -> { Events::EventCancellation.where(event: @event).count }, 1 do
        post url, params: payload, headers: owner_headers.merge("Idempotency-Key" => "cancel-1"), as: :json
      end
      assert_response :created
      assert_equal "cancelled", @event.reload.status
      assert_equal "pending", JSON.parse(response.body).dig("data", "status")
      assert_equal "postponed", JSON.parse(response.body).dig("data", "attendee_reason")
    end

    test "outsider cannot initiate a cancellation" do
      post url, params: payload, headers: user_headers.merge("Idempotency-Key" => "cancel-2"), as: :json
      assert_response :forbidden
    end

    test "event manager cannot initiate a cancellation" do
      Events::EventStaffAssignment.create!(
        event: @event,
        user: core_users(:support),
        organization: @event.organization,
        role: "manager",
        status: "active"
      )
      headers = { "Authorization" => "Bearer #{issue_token(:support)}", "Idempotency-Key" => "cancel-manager" }
      post url, params: payload, headers:, as: :json
      assert_response :forbidden
    end

    test "serializer excludes internal notes and treasury state" do
      post url, params: payload, headers: owner_headers.merge("Idempotency-Key" => "cancel-private"), as: :json
      assert_response :created
      data = JSON.parse(response.body).fetch("data")
      assert_not data.key?("internal_note")
      assert_not data.key?("last_error")
      assert_not data.key?("lock_version")
    end

    test "missing Idempotency-Key header returns 400" do
      post url, params: payload, headers: owner_headers, as: :json
      assert_response :bad_request
      assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
    end

    test "empty Idempotency-Key header returns 400" do
      post url, params: payload, headers: owner_headers.merge("Idempotency-Key" => ""), as: :json
      assert_response :bad_request
      assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
    end

    test "cancelling an already cancelled event returns an error" do
      post url, params: payload, headers: owner_headers.merge("Idempotency-Key" => "first"), as: :json
      assert_response :created

      post url, params: payload, headers: owner_headers.merge("Idempotency-Key" => "second"), as: :json
      assert_response :unprocessable_entity
      assert_equal "already_cancelled", JSON.parse(response.body)["code"]
    end

    test "replaying the same Idempotency-Key header is a no-op" do
      headers = owner_headers.merge("Idempotency-Key" => "replay-1")
      post url, params: payload, headers: headers, as: :json
      assert_response :created
      count = Events::EventCancellation.where(event: @event).count

      post url, params: payload, headers: headers, as: :json
      assert_response :success
      assert_equal count, Events::EventCancellation.where(event: @event).count
    end
  end
end
