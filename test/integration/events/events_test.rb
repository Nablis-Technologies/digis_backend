# frozen_string_literal: true

require "test_helper"

class EventsEventsTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers

  setup do
    @organization = organizations_organizations(:one)
    make_verified(@organization)
  end

  def make_verified(organization)
    Core::Review.create!(
      reviewable: organization,
      context: "verification",
      status: "approved"
    )
  end

  test "an authenticated organizer can create a draft event" do
    payload = {
      event: {
        title: "New Year Concert",
        description: "A brand new year concert",
        visibility: "private",
        timezone: "Africa/Addis_Ababa",
        currency: "ETB",
        organization_id: @organization.id
      }
    }

    post "/events", params: payload, headers: admin_headers, as: :json
    assert_response :created
    body = JSON.parse(response.body).dig("data")
    assert_equal "New Year Concert", body["title"]
    assert_equal "draft", body["status"]
    assert Events::Event.exists?(body["id"])
    assert_equal "Event created successfully", JSON.parse(response.body)["message"]
  end

  test "an organizer can create an event with categories in one request" do
    payload = {
      event: {
        title: "Categorised Concert",
        description: "has categories",
        visibility: "public",
        timezone: "Africa/Addis_Ababa",
        currency: "ETB",
        organization_id: @organization.id,
        category_ids: [ events_categories(:music).id ]
      }
    }

    post "/events", params: payload, headers: admin_headers, as: :json
    assert_response :created
    event = Events::Event.find(JSON.parse(response.body).dig("data", "id"))
    assert_equal 1, event.event_categories.count

    post "/events/#{event.id}/publish", headers: admin_headers.merge("Idempotency-Key" => "publish-1"), as: :json
    assert_response :success
    assert_equal "published", event.reload.status
  end

  test "an organizer can attach categories to a draft event via update" do
    event = Events::Create.call(
      organization: @organization,
      actor: core_users(:super_admin),
      attributes: { title: "Draft No Cat", description: "d", visibility: "public",
                    timezone: "Africa/Addis_Ababa", currency: "ETB" }
    ).value
    assert_equal 0, event.event_categories.count

    patch "/events/#{event.id}", params: {
      event: { category_ids: [ events_categories(:music).id ] }
    }, headers: admin_headers, as: :json
    assert_response :success
    assert_equal 1, event.reload.event_categories.count
  end

  test "creating an event requires authentication" do
    payload = { event: { title: "No Auth", organization_id: @organization.id } }
    post "/events", params: payload, as: :json
    assert_response :unauthorized
  end

  test "an organizer can list their draft events" do
    get "/events", headers: admin_headers, as: :json
    assert_response :success
    bodies = JSON.parse(response.body).dig("data")
    assert_anybody = bodies.any? { |e| e["id"] == events_events(:draft_concert).id }
    assert assert_anybody
  end

  test "publishing a ready event flips status and exposes public data" do
    event = events_events(:ready_listing)
    make_verified(event.organization)

    post "/events/#{event.id}/publish", headers: admin_headers.merge("Idempotency-Key" => "publish-2"), as: :json
    assert_response :success
    body = JSON.parse(response.body).dig("data")
    assert_equal "published", body["status"]
    assert body["published_at"].present?

    get "/events/#{event.id}", headers: admin_headers, as: :json
    assert_response :success
  end

  test "publishing an unverified organization is forbidden" do
    event = events_events(:ready_listing)

    post "/events/#{event.id}/publish", headers: admin_headers.merge("Idempotency-Key" => "publish-3"), as: :json
    assert_response :unprocessable_entity
    assert_equal "draft", event.reload.status
  end

  test "an organization owner cannot publish until the org is verified" do
    # attendee is a plain (non super/admin) owner of org :one, org left unverified
    user = core_users(:attendee)
    @organization.memberships.where(user: user).delete_all
    @organization.memberships.create!(user: user, role: :admin, status: :active)
    @organization.reviews.where(context: "verification").delete_all
    @organization.reload

    event = Events::Create.call(
      organization: @organization,
      actor: user,
      attributes: { title: "T", description: "d", visibility: "public",
                    timezone: "Africa/Addis_Ababa", currency: "ETB" }
    ).value

    post "/events/#{event.id}/publish", headers: user_headers.merge("Idempotency-Key" => "publish-4"), as: :json
    assert_response :forbidden
    assert_equal "draft", event.reload.status
  end

  test "publishing without an Idempotency-Key header returns 400" do
    event = events_events(:ready_listing)
    post "/events/#{event.id}/publish", headers: admin_headers, as: :json
    assert_response :bad_request
    assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
  end
end
