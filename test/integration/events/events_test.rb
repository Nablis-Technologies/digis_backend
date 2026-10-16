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
    assert_equal @organization.id, body["organization_id"]
    assert_equal "draft", body["status"]
    assert Events::Event.exists?(body["id"])
    assert_equal "Event created successfully", JSON.parse(response.body)["message"]
  end

  test "event creation persists the canonical age restriction and audits the actor" do
    age_restriction = { "has_restriction" => true, "min_age" => 18, "max_age" => 30 }
    post "/events", params: event_payload(
      event_setting: { config: { age_restriction: age_restriction.merge(internal_note: "drop me") } }
    ), headers: admin_headers, as: :json

    assert_response :created
    event_id = response.parsed_body.dig("data", "id")
    setting = Events::EventSetting.find_by!(event_id: event_id)
    assert_equal age_restriction, setting.config["age_restriction"]

    audit = Core::AuditLog.find_by!(auditable_type: "Events::Event", auditable_id: event_id,
                                    action: "event.created")
    assert_equal core_users(:super_admin).id, audit.actor_id
    assert_equal age_restriction, audit.audited_changes.dig("event_setting", "age_restriction")
  end

  test "event creation rejects an invalid age restriction without creating an event" do
    initial_count = Events::Event.count
    post "/events", params: event_payload(
      event_setting: { config: { age_restriction: { has_restriction: true, min_age: 121 } } }
    ), headers: admin_headers, as: :json

    assert_response :unprocessable_entity
    assert_equal initial_count, Events::Event.count
  end

  test "event update merges only age restriction, preserves sibling settings, and audits actual changes" do
    event = events_events(:draft_concert)
    setting = event.event_setting
    setting.update!(config: setting.config.merge("internal_flag" => "preserve me"))
    first_value = { "has_restriction" => true, "min_age" => 18 }

    patch "/events/#{event.id}", params: {
      event: { event_setting: { config: { age_restriction: first_value } } }
    }, headers: admin_headers, as: :json

    assert_response :success
    assert_equal first_value, setting.reload.config["age_restriction"]
    assert_equal "preserve me", setting.config.fetch("internal_flag")

    audit_scope = Core::AuditLog.where(
      auditable_type: "Events::Event", auditable_id: event.id, action: "event.age_restriction.updated"
    )
    assert_equal 1, audit_scope.count
    audit = audit_scope.sole
    assert_equal core_users(:super_admin).id, audit.actor_id
    assert_equal [ nil, first_value ], audit.audited_changes.fetch("age_restriction")

    patch "/events/#{event.id}", params: {
      event: { event_setting: { config: { age_restriction: first_value } } }
    }, headers: admin_headers, as: :json

    assert_response :success
    assert_equal 1, audit_scope.count, "an unchanged setting must not create audit noise"
  end

  test "omitting age restriction on event update leaves the current setting unchanged" do
    event = events_events(:draft_concert)
    setting = event.event_setting
    age_restriction = { "has_restriction" => true, "max_age" => 21 }
    setting.update!(config: setting.config.merge("age_restriction" => age_restriction))

    patch "/events/#{event.id}", params: { event: { title: "Changed without settings" } },
          headers: admin_headers, as: :json

    assert_response :success
    assert_equal age_restriction, setting.reload.config.fetch("age_restriction")
  end

  test "invalid age restriction rolls back other event updates" do
    event = events_events(:draft_concert)
    original_title = event.title
    original_category_ids = event.category_ids
    original_config = event.event_setting.config

    patch "/events/#{event.id}", params: {
      event: {
        title: "Must Roll Back",
        category_ids: [ events_categories(:conference).id ],
        event_setting: { config: { age_restriction: { has_restriction: true, min_age: "18" } } }
      }
    }, headers: admin_headers, as: :json

    assert_response :unprocessable_entity
    assert_equal original_title, event.reload.title
    assert_equal original_category_ids, event.category_ids
    assert_equal original_config, event.event_setting.reload.config
    assert_equal 0, Core::AuditLog.where(
      auditable_type: "Events::Event", auditable_id: event.id, action: "event.age_restriction.updated"
    ).count
  end

  test "event update rejects age restriction supplied outside config" do
    event = events_events(:draft_concert)
    original_title = event.title
    original_config = event.event_setting.config

    patch "/events/#{event.id}", params: {
      event: {
        title: "Misplaced value must not be ignored",
        event_setting: { age_restriction: { has_restriction: false } }
      }
    }, headers: admin_headers, as: :json

    assert_response :unprocessable_entity
    assert_equal original_title, event.reload.title
    assert_equal original_config, event.event_setting.reload.config
  end

  test "event update rejects an array age bound when another valid bound is present" do
    event = events_events(:ready_listing)
    original_config = event.event_setting.config

    patch "/events/#{event.id}", params: {
      event: { event_setting: { config: { age_restriction: { has_restriction: true, min_age: [], max_age: 18 } } } }
    }, headers: admin_headers, as: :json

    assert_response :unprocessable_entity
    assert_equal original_config, event.event_setting.reload.config
  end

  test "event update rejects an object as an age bound" do
    event = events_events(:draft_concert)
    original_config = event.event_setting.config

    patch "/events/#{event.id}", params: {
      event: { event_setting: { config: { age_restriction: { has_restriction: true, min_age: { value: 18 }, max_age: 21 } } } }
    }, headers: admin_headers, as: :json

    assert_response :unprocessable_entity
    assert_equal original_config, event.event_setting.reload.config
  end

  test "age restriction update locks the current setting row before merging and auditing" do
    event = events_events(:draft_concert)
    setting = event.event_setting
    setting.update!(config: setting.config.merge("concurrent_sibling" => "preserve"))
    lock_queries = []
    subscription = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s
      lock_queries << sql if sql.include?("events_event_settings") && sql.match?(/FOR UPDATE/i)
    end

    patch "/events/#{event.id}", params: {
      event: { event_setting: { config: { age_restriction: { has_restriction: true, min_age: 18 } } } }
    }, headers: admin_headers, as: :json

    assert_response :success
    assert_equal "preserve", setting.reload.config.fetch("concurrent_sibling")
    assert lock_queries.any?, "age restriction write should lock the current event setting row"
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
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
    assert_equal event.organization_id, list_event["organization_id"]
    assert_equal event.organization.name, list_event.dig("organization", "name")
    assert_equal "Music", list_event.dig("categories", 0, "name")
    assert_equal "Grand Palace", list_event.dig("event_dates", 0, "venue", "name")
    assert_equal 5000, list_event.dig("event_dates", 0, "capacity", "limit")
    assert_equal 1, list_event.fetch("event_media").length
    assert_equal "cover", list_event.dig("event_media", 0, "type")

    get "/events/#{event.id}", headers: admin_headers, as: :json

    assert_response :success
    detail = response.parsed_body.fetch("data")
    assert_equal event.organization_id, detail["organization_id"]
    assert_equal 2, detail.fetch("event_media").length
    assert_equal "gallery", detail.dig("event_media", 1, "type")
  end

  test "organizer age restriction appears on detail and mutations but not event cards" do
    user = create_event_list_user
    organization = create_event_list_organization("Age Restriction")
    make_verified(organization)
    organization.memberships.create!(user:, role: :owner, status: :active)
    initial_restriction = { "has_restriction" => true, "min_age" => 18 }

    post "/events", params: event_payload(
      organization_id: organization.id,
      event_setting: { config: { age_restriction: initial_restriction } }
    ), headers: headers_for(user), as: :json

    assert_response :created
    created = response.parsed_body.fetch("data")
    event_id = created.fetch("id")
    assert_equal initial_restriction, created.dig("event_setting", "config", "age_restriction")
    assert_equal({ "age_restriction" => initial_restriction }, created.dig("event_setting", "config"))

    event = Events::Event.find(event_id)
    event.event_setting.update_column(:config, {
      "public_guest_limit" => 100,
      "internal_flag" => "never serialize",
      "age_restriction" => initial_restriction.merge("internal_note" => "never serialize")
    })

    get "/events/#{event_id}", headers: headers_for(user), as: :json

    assert_response :success
    detail = response.parsed_body.fetch("data")
    assert_equal({ "age_restriction" => initial_restriction }, detail.dig("event_setting", "config"))

    get "/events", headers: headers_for(user), as: :json

    assert_response :success
    card = response.parsed_body.fetch("data").find { |item| item.fetch("id") == event_id }
    refute card.key?("event_setting")

    updated_restriction = { "has_restriction" => true, "min_age" => 21 }
    patch "/events/#{event_id}", params: {
      event: { event_setting: { config: { age_restriction: updated_restriction } } }
    }, headers: headers_for(user), as: :json

    assert_response :success
    mutation = response.parsed_body.fetch("data")
    assert_equal({ "age_restriction" => updated_restriction }, mutation.dig("event_setting", "config"))
  end

  test "organizer event detail safely omits a missing event setting" do
    event = events_events(:draft_concert)
    event.event_setting.destroy!

    get "/events/#{event.id}", headers: admin_headers, as: :json

    assert_response :success
    refute response.parsed_body.fetch("data").key?("event_setting")
  end

  test "publish response retains the organizer-safe setting projection" do
    event = events_events(:ready_listing)
    make_verified(event.organization)
    make_publishable(event)
    event.event_setting.update_column(:config, {
      "age_restriction" => {
        "has_restriction" => true,
        "min_age" => 18,
        "internal_note" => "never serialize"
      },
      "internal_flag" => "never serialize"
    })

    post "/events/#{event.id}/publish", headers: admin_headers.merge("Idempotency-Key" => "publish-age-safe"), as: :json

    assert_response :success
    config = response.parsed_body.dig("data", "event_setting", "config")
    assert_equal({ "age_restriction" => { "has_restriction" => true, "min_age" => 18 } }, config)
  end

  test "organizer event index excludes unrelated public events" do
    user = create_event_list_user
    organization = create_event_list_organization("Managed")
    organization.memberships.create!(user:, role: :owner, status: :active)
    create_event_list_event(organization:, user:, status: "draft", visibility: "private")

    unrelated_organization = create_event_list_organization("Unrelated")
    unrelated_public_event = create_event_list_event(
      organization: unrelated_organization, user:, status: "published", visibility: "public"
    )

    get "/events", headers: headers_for(user), as: :json

    assert_response :success
    event_ids = response.parsed_body.fetch("data").map { |event| event.fetch("id") }
    assert_not_includes event_ids, unrelated_public_event.id
  end

  test "organizer event index includes an event with an active staff assignment" do
    user = create_event_list_user
    organization = create_event_list_organization("Assigned")
    event = create_event_list_event(organization:, user:, status: "draft", visibility: "private")
    Events::EventStaffAssignment.create!(event:, user:, organization:, role: "staff", status: "active")

    get "/events", headers: headers_for(user), as: :json

    assert_response :success
    event_ids = response.parsed_body.fetch("data").map { |item| item.fetch("id") }
    assert_includes event_ids, event.id
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

  def event_payload(attributes = {})
    {
      event: {
        title: "Age Restricted Event",
        description: "Age setting integration coverage",
        visibility: "private",
        timezone: "Africa/Addis_Ababa",
        currency: "ETB",
        organization_id: @organization.id
      }.merge(attributes)
    }
  end

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

  def create_event_list_user
    Core::User.create!(phone: "+251915#{format("%06d", SecureRandom.random_number(1_000_000))}")
  end

  def create_event_list_organization(label)
    Organizations::Organization.create!(
      name: "#{label} Event List Org #{SecureRandom.hex(4)}",
      organizer_type: "individual",
      category: "conference"
    )
  end

  def create_event_list_event(organization:, user:, status:, visibility:)
    Events::Event.create!(
      organization:, created_by: user,
      title: "#{status} #{SecureRandom.hex(4)}",
      slug: "#{status}-#{SecureRandom.hex(6)}",
      status:, visibility:, timezone: "Africa/Addis_Ababa", currency: "ETB"
    )
  end

  def headers_for(user)
    { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
  end
end
