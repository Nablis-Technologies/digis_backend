# frozen_string_literal: true

require "test_helper"

class EventsAuthorizationMatrixTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers

  def make_verified(organization)
    Core::Review.create!(
      reviewable: organization,
      context: "verification",
      status: "approved"
    )
  end

  def setup
    @event = events_events(:ready_listing)
    make_verified(@event.organization)
    Events::ReplaceCategories.call(
      event: @event,
      category_ids: [ events_categories(:music).id ],
      actor: core_users(:super_admin)
    )
    make_publishable(@event)
    @event.update!(visibility: "public")
    post "/events/#{@event.id}/publish",
         headers: admin_headers.merge("Idempotency-Key" => "matrix-publish"), as: :json
    @slug = @event.reload.slug
  end

  test "public discovery exposes only attendee-safe fields" do
    get "/public/events/#{@slug}", as: :json
    assert_response :success
    data = JSON.parse(response.body)["data"]
    assert data.key?("title")
    assert data.key?("event_dates")
    assert data.key?("event_setting")
    assert data.dig("event_setting", "config").is_a?(Hash)
    refute data.key?("status")
    refute data.key?("version")
    refute data.dig("event_setting", "config").key?("internal_flag")
  end

  test "unauthenticated request to the owner endpoint is rejected" do
    get "/events/#{@event.id}", as: :json
    assert_response :unauthorized
  end

  test "authenticated non-owner can view a public published event" do
    get "/events/#{@event.id}", headers: user_headers, as: :json
    assert_response :success
  end

  test "authenticated non-owner is forbidden from a draft event" do
    draft = events_events(:draft_concert)
    get "/events/#{draft.id}", headers: user_headers, as: :json
    assert_response :forbidden
  end

  test "owner sees the full serializer with status and version" do
    get "/events/#{@event.id}", headers: admin_headers, as: :json
    assert_response :success
    data = JSON.parse(response.body)["data"]
    assert data.key?("status")
    assert data.key?("version")
    assert data.key?("cancelled_at")
  end

  test "a manager staff assignment grants access to the owner endpoint" do
    Events::EventStaffAssignment.create!(
      event: @event, user: core_users(:attendee), organization: @event.organization,
      role: "manager", status: "active"
    )
    get "/events/#{@event.id}", headers: user_headers, as: :json
    assert_response :success
  end

  test "a scanner staff assignment grants access to the owner endpoint" do
    Events::EventStaffAssignment.create!(
      event: @event, user: core_users(:attendee), organization: @event.organization,
      role: "scanner", status: "active"
    )
    get "/events/#{@event.id}", headers: user_headers, as: :json
    assert_response :success
  end

  test "platform admin reaches the admin surface" do
    get "/admin/events/#{@event.id}", headers: admin_headers, as: :json
    assert_response :success
  end

  test "a draft event is not publicly discoverable" do
    draft = events_events(:draft_concert)
    get "/public/events/#{draft.slug}", as: :json
    assert_response :not_found
  end
end
