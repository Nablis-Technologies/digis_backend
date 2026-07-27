# frozen_string_literal: true

require "test_helper"

module Events
  class EventScheduleChangesIntegrationTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    def setup
      @event = events_events(:ready_listing)
      @date = @event.event_dates.create!(
        starts_at: Time.zone.local(2026, 9, 1, 20),
        ends_at: Time.zone.local(2026, 9, 1, 22)
      )
    end

    def payload
      {
        schedule_change: {
          changes: [
            {
              event_date_id: @date.id,
              new_start_at: "2026-09-02T20:00:00Z",
              new_end_at: "2026-09-02T22:00:00Z"
            }
          ]
        }
      }
    end

    def url
      "/events/#{@event.id}/event_schedule_changes"
    end

    test "owner can create a schedule change" do
      assert_difference -> { Events::EventDateChange.where(event: @event).count }, 1 do
        post url, params: payload, headers: owner_headers.merge("Idempotency-Key" => "change-1"), as: :json
      end
      assert_response :created
    end

    test "outsider cannot create a schedule change" do
      post url, params: payload, headers: user_headers.merge("Idempotency-Key" => "change-2"), as: :json
      assert_response :forbidden
    end

    test "missing Idempotency-Key header returns 400" do
      post url, params: payload, headers: owner_headers, as: :json
      assert_response :bad_request
      assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
    end

    test "replaying the same Idempotency-Key header is a no-op" do
      headers = owner_headers.merge("Idempotency-Key" => "replay-1")
      post url, params: payload, headers: headers, as: :json
      assert_response :created
      version = @event.reload.version
      count = Events::EventDateChange.where(event: @event).count

      post url, params: payload, headers: headers, as: :json
      assert_response :success
      assert_equal version, @event.reload.version
      assert_equal count, Events::EventDateChange.where(event: @event).count
    end
  end
end
