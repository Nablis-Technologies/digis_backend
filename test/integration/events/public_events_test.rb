# frozen_string_literal: true

require "test_helper"

class EventsPublicEventsTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers

  setup do
    @event = events_events(:ready_listing)
    Core::Review.create!(
      reviewable: @event.organization,
      context: "verification",
      status: "approved"
    )
    make_publishable(@event)
    Events::Publish.call(event: @event, actor: core_users(:super_admin),
                         idempotency_key: SecureRandom.uuid)
  end

  test "published public events are discoverable without auth" do
    get "/public/events", as: :json
    assert_response :success
    bodies = JSON.parse(response.body).dig("data")
    assert bodies.any? { |e| e["id"] == @event.id }
  end

  test "private draft events are excluded from public discovery" do
    get "/public/events", as: :json
    bodies = JSON.parse(response.body).dig("data")
    refute bodies.any? { |e| e["id"] == events_events(:draft_concert).id }
  end

  test "public event detail exposes only attendee-safe fields" do
    get "/public/events/#{@event.slug}", as: :json
    assert_response :success
    body = JSON.parse(response.body).dig("data")
    assert_equal @event.id, body["id"]
    assert_includes body.keys, "title"
    refute_includes body.keys, "cancelled_at"
    refute_includes body.keys, "internal_notes"
  end

  test "private event is not directly lookupable by unauthenticated user" do
    get "/public/events/#{events_events(:draft_concert).slug}", as: :json
    assert_response :not_found
  end
end
