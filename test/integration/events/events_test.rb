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
    make_publishable(event)

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

  test "organizer event responses include bounded display context and media" do
    event = events_events(:ready_listing)
    event.categories.load
    event.event_dates.create!(
      name: "Opening night",
      starts_at: 2.days.from_now,
      ends_at: 2.days.from_now + 3.hours,
      status: "scheduled",
      venue: events_venues(:grand_palace),
      venue_capacity: 5000,
      held_venue_count: 12,
      issued_venue_count: 300
    )
    create_media(event:, type: "cover", position: 0)
    create_media(event:, type: "gallery", position: 1)

    get "/events", headers: admin_headers, as: :json

    assert_response :success
    list_event = response.parsed_body.fetch("data").find { |item| item.fetch("id") == event.id }
    assert_equal event.organization.name, list_event.dig("organization", "name")
    assert_equal "Music", list_event.dig("categories", 0, "name")
    assert_equal "Grand Palace", list_event.dig("event_dates", 0, "venue", "name")
    assert_equal 5000, list_event.dig("event_dates", 0, "capacity", "limit")
    assert_equal 1, list_event.fetch("event_media").length
    assert_equal "cover", list_event.dig("event_media", 0, "type")

    get "/events/#{event.id}", headers: admin_headers, as: :json

    assert_response :success
    detail = response.parsed_body.fetch("data")
    assert_equal 2, detail.fetch("event_media").length
    assert_equal "gallery", detail.dig("event_media", 1, "type")
  end

  test "event list responses are bounded and expose pagination metadata" do
    26.times do |index|
      Events::Event.create!(
        organization: @organization,
        created_by: core_users(:super_admin),
        title: "Paged event #{index}",
        slug: "paged-event-#{index}-#{SecureRandom.hex(4)}",
        status: "draft",
        visibility: "private",
        timezone: "Africa/Addis_Ababa",
        currency: "ETB"
      )
    end

    get "/events", headers: admin_headers, as: :json
    assert_response :success
    assert_equal 25, response.parsed_body.fetch("data").length

    get "/events?page=2&per_page=10", headers: admin_headers, as: :json
    assert_response :success
    pagination = response.parsed_body.fetch("pagination")
    assert_equal 10, response.parsed_body.fetch("data").length
    assert_equal 28, pagination.fetch("total_count")
    assert_equal 2, pagination.fetch("current_page")
    assert_equal 3, pagination.fetch("total_pages")
  end

  test "publishing a ready event flips status and exposes public data" do
    event = events_events(:ready_listing)
    make_verified(event.organization)
    make_publishable(event)

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

  test "the missing Idempotency-Key response is the standard error envelope" do
    # The envelope is not cosmetic. Envelope-aware clients (digis-web) only read
    # `error` when `success` is exactly false; a bare `{ error:, code: }` hash
    # makes them fall back to the HTTP status text and show "Bad Request".
    event = events_events(:ready_listing)
    post "/events/#{event.id}/publish", headers: admin_headers, as: :json

    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_equal "missing_idempotency_key", body["code"]
    assert_predicate body["error"], :present?
  end

  test "index exposes updated_at so the list can show when an event changed" do
    # `updated_at` is sortable (`allowed_order_columns`), so a list that renders
    # a sort control for it must be able to read it back. When it was absent the
    # UI rendered "Invalid Date" on every row.
    get "/events?page=1", headers: admin_headers, as: :json

    assert_response :success
    events = response.parsed_body.fetch("data")
    assert_predicate events, :any?
    events.each do |event|
      assert_predicate event["updated_at"], :present?, "expected updated_at on event #{event['id']}"
    end
  end

  test "index filters by an allowlisted ransack attribute" do
    get "/events?page=1&q[status_eq]=draft", headers: admin_headers, as: :json

    assert_response :success
    statuses = response.parsed_body.fetch("data").map { |event| event.fetch("status") }.uniq
    assert_equal [ "draft" ], statuses
    assert_operator response.parsed_body.fetch("pagination").fetch("total_count"), :>, 0
  end

  test "index searches event titles case-insensitively" do
    Events::Event.create!(
      organization: @organization,
      created_by: core_users(:super_admin),
      title: "Unique Zambezi Festival",
      slug: "unique-zambezi-#{SecureRandom.hex(4)}",
      status: "draft",
      visibility: "private",
      timezone: "Africa/Addis_Ababa",
      currency: "ETB"
    )

    get "/events?page=1&q[title_cont]=zambezi", headers: admin_headers, as: :json

    assert_response :success
    titles = response.parsed_body.fetch("data").map { |event| event.fetch("title") }
    assert_equal [ "Unique Zambezi Festival" ], titles
  end

  test "index orders by an allowlisted column" do
    2.times do |index|
      Events::Event.create!(
        organization: @organization,
        created_by: core_users(:super_admin),
        title: "Zebra Ordering #{index}",
        slug: "zebra-ordering-#{index}-#{SecureRandom.hex(4)}",
        status: "draft",
        visibility: "private",
        timezone: "Africa/Addis_Ababa",
        currency: "ETB"
      )
    end

    get "/events?page=1&q[title_cont]=Zebra Ordering&order_by=title&order_direction=asc",
        headers: admin_headers, as: :json
    assert_response :success
    assert_equal [ "Zebra Ordering 0", "Zebra Ordering 1" ],
                 response.parsed_body.fetch("data").map { |event| event.fetch("title") }

    get "/events?page=1&q[title_cont]=Zebra Ordering&order_by=title&order_direction=desc",
        headers: admin_headers, as: :json
    assert_response :success
    assert_equal [ "Zebra Ordering 1", "Zebra Ordering 0" ],
                 response.parsed_body.fetch("data").map { |event| event.fetch("title") }
  end

  test "index falls back to id when the order column is not allowlisted" do
    get "/events?page=1&order_by=created_by_id&order_direction=asc",
        headers: admin_headers, as: :json

    assert_response :success
    ids = response.parsed_body.fetch("data").map { |event| event.fetch("id") }
    assert_equal ids.sort, ids
  end

  private

  def create_media(event:, type:, position:)
    media = event.event_media.build(
      type:, position:, created_by: core_users(:super_admin), alt_text: "Event media"
    )
    media.file.attach(
      io: File.open(Rails.root.join("test/fixtures/files/pixel.png")),
      filename: "pixel.png",
      content_type: "image/png"
    )
    media.save!
    media
  end
end
