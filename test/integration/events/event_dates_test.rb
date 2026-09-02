# frozen_string_literal: true

require "test_helper"
require "active_job/test_helper"

module Events
  class EventDatesTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include ActiveJob::TestHelper

    def setup
      @event = events_events(:ready_listing)
    end

    test "owner can list and create an event date" do
      get "/events/#{@event.id}/event_dates", headers: owner_headers, as: :json
      assert_response :ok
      assert JSON.parse(response.body)["data"].is_a?(Array)

      initial_schedule_version = @event.reload.schedule_version
      assert_difference -> { Events::EventDate.count }, 1 do
        post "/events/#{@event.id}/event_dates",
             params: { event_date: { starts_at: "2026-08-01T20:00:00Z", ends_at: "2026-08-01T22:00:00Z", status: "scheduled" } },
             headers: owner_headers, as: :json
      end
      assert_response :created
      body = JSON.parse(response.body)
      assert_equal "scheduled", body.dig("data", "status")
      assert_equal initial_schedule_version + 1, @event.reload.schedule_version
    end

    test "owner date responses include the venue summary and event-scoped capacity" do
      date = @event.event_dates.create!(
        name: "Opening night",
        starts_at: 2.days.from_now,
        ends_at: 2.days.from_now + 3.hours,
        status: "scheduled",
        venue: events_venues(:grand_palace),
        venue_capacity: 5000,
        held_venue_count: 12,
        issued_venue_count: 300
      )

      get "/events/#{@event.id}/event_dates", headers: owner_headers, as: :json

      assert_response :ok
      payload = response.parsed_body.fetch("data").find { |item| item.fetch("id") == date.id }
      assert_equal "Grand Palace", payload.dig("venue", "name")
      assert_equal "Addis Ababa", payload.dig("venue", "city")
      assert_equal(
        { "limit" => 5000, "held" => 12, "issued" => 300, "available" => 4688 },
        payload.fetch("capacity")
      )
    end

    test "outsider cannot create an event date" do
      post "/events/#{@event.id}/event_dates",
           params: { event_date: { starts_at: "2026-08-01T20:00:00Z", ends_at: "2026-08-01T22:00:00Z", status: "scheduled" } },
           headers: user_headers, as: :json
      assert_response :forbidden
    end

    test "owner can manage participants" do
      date = Events::EventDate.create!(
        event: @event, starts_at: "2026-08-01T20:00:00Z", ends_at: "2026-08-01T22:00:00Z", status: "scheduled"
      )

      assert_difference -> { Events::EventParticipant.count }, 1 do
        post "/events/#{@event.id}/event_participants",
             params: { event_participant: { event_date_id: date.id, name: "Headliner", type: "performer" } },
             headers: owner_headers, as: :json
      end
      assert_response :created
    end

    test "owner can manage access zones" do
      initial_schedule_version = @event.reload.schedule_version
      assert_difference -> { Events::AccessZone.count }, 1 do
        post "/events/#{@event.id}/access_zones",
             params: { access_zone: { type: "venue", name: "Main Floor", code: "MAIN" } },
             headers: owner_headers, as: :json
      end
      assert_response :created
      assert_equal initial_schedule_version + 1, @event.reload.schedule_version

      zone_id = JSON.parse(response.body).dig("data", "id")
      patch "/events/#{@event.id}/access_zones/#{zone_id}",
            params: { access_zone: { name: "Main Floor Updated" } },
            headers: owner_headers, as: :json
      assert_response :success
      assert_equal initial_schedule_version + 2, @event.reload.schedule_version

      delete "/events/#{@event.id}/access_zones/#{zone_id}", headers: owner_headers, as: :json
      assert_response :success
      assert_equal initial_schedule_version + 3, @event.reload.schedule_version
    end

    test "destroying an event date advances the schedule version" do
      date = Events::EventDate.create!(
        event: @event,
        starts_at: "2026-08-01T20:00:00Z",
        ends_at: "2026-08-01T22:00:00Z",
        status: "scheduled"
      )
      initial_schedule_version = @event.reload.schedule_version

      delete "/events/#{@event.id}/event_dates/#{date.id}", headers: owner_headers, as: :json

      assert_response :success
      assert_equal initial_schedule_version + 1, @event.reload.schedule_version
    end

    test "outsider cannot manage access zones" do
      post "/events/#{@event.id}/access_zones",
           params: { access_zone: { type: "venue", name: "Main Floor", code: "INTRUDER" } },
           headers: user_headers, as: :json
      assert_response :forbidden
    end

    test "configuring a recurrence rule materializes dates" do
      assert_enqueued_with(job: Events::MaterializeRecurrenceJob) do
        post "/events/#{@event.id}/recurrence_rule",
             params: {
               recurrence_rule: {
                 rrule: "FREQ=DAILY;COUNT=3",
                 timezone: "Africa/Addis_Ababa",
                 dtstart_local: "2026-08-01 20:00:00",
                 duration_seconds: 3600
               }
             },
             headers: owner_headers, as: :json
      end
      assert_response :created

      assert_difference -> { Events::EventDate.count }, 3 do
        perform_enqueued_jobs
      end
    end
  end
end
