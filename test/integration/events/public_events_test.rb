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
    @event.event_dates.update_all(
      status: "scheduled", starts_at: 2.days.from_now, ends_at: 2.days.from_now + 2.hours
    )
    @event.event_dates.first.update!(venue: events_venues(:grand_palace), name: "Main show")
    @event.event_setting.update!(config: {
      event_type: "rsvp", allow_waitlist: true, public_guest_limit: 10, internal_flag: true
    })
    Events::Publish.call(event: @event, actor: core_users(:super_admin),
                         idempotency_key: SecureRandom.uuid)
  end

  test "published public events are discoverable without auth" do
    get "/public/events", as: :json
    assert_response :success
    bodies = JSON.parse(response.body).dig("data")
    assert_equal 25, response.parsed_body.dig("pagination", "per_page")
    event = bodies.find { |item| item["id"] == @event.id }
    assert event
    assert_equal "upcoming", event.fetch("event_lifecycle")
    assert_includes %w[
      available unavailable coming_soon sold_out sales_closed no_public_tickets no_eligible_dates
    ], event.fetch("ticket_availability")
    refute event.key?("has_available_tickets")
    assert_equal "10", event.dig("event_setting", "config", "public_guest_limit").to_s
    refute event.dig("event_setting", "config").key?("event_type")
    refute event.dig("event_setting", "config").key?("allow_waitlist")
    assert_equal "Main show", event.dig("next_event_date", "name")
    assert_equal "Grand Palace", event.dig("next_event_date", "venue", "name")
    assert_equal "Addis Ababa", event.dig("next_event_date", "venue", "city")
    refute event.key?("event_dates")
    assert event.dig("event_media", 0, "file", "medium").present?
    refute event.dig("event_setting", "config").key?("internal_flag")
  end

  test "public event detail exposes a safe lineup with whole-event and date-specific participants" do
    event_date = @event.event_dates.first
    date_participant = @event.event_participants.create!(
      event_date:,
      artist_id: events_artists(:teddy).id,
      name: "Date performer",
      type: "performer",
      description: "Appears on this date",
      display_order: 1,
      metadata: { internal_note: "not public" }
    )
    event_participant = @event.event_participants.create!(
      name: "Event host",
      type: "host",
      description: "Applies to all event dates",
      display_order: 2,
      metadata: { internal_note: "also not public" }
    )
    tied_participant_ids = %w[
      018f0000-0000-7000-8000-000000000001
      018f0000-0000-7000-8000-000000000002
    ]
    tied_participant_ids.reverse_each do |id|
      @event.event_participants.create!(
        id:,
        name: "Same-order performer #{id.last}",
        type: "performer",
        display_order: 3
      )
    end

    get "/public/events/#{@event.slug}", as: :json

    assert_response :success
    data = response.parsed_body.fetch("data")
    participants = data.fetch("event_participants")
    assert_equal [ date_participant.id, event_participant.id, *tied_participant_ids ],
                 participants.map { |item| item.fetch("id") }
    assert_equal event_date.id, participants.first.fetch("event_date_id")
    assert_nil participants[1].fetch("event_date_id")
    assert_equal events_artists(:teddy).id, participants.first.fetch("artist_id")
    assert_equal %w[artist_id description display_order event_date_id id name type],
                 participants.first.keys.sort
    assert_equal "Applies to all event dates", participants[1].fetch("description")

    get "/public/events", as: :json

    assert_response :success
    card = response.parsed_body.fetch("data").find { |item| item.fetch("id") == @event.id }
    refute card.key?("event_participants")
  end

  test "public event list is paginated with stable timestamp and ID ordering" do
    first = create_public_event("Later page one", published_at: 2.hours.from_now)
    second = create_public_event("Later page two", published_at: 1.hour.from_now)

    get "/public/events?page=1&per_page=1", as: :json
    assert_response :success
    first_page = response.parsed_body
    assert_equal [ first.id ], first_page.fetch("data").map { |event| event.fetch("id") }
    assert_equal 1, first_page.dig("pagination", "current_page")
    assert_equal 1, first_page.dig("pagination", "per_page")
    assert_operator first_page.dig("pagination", "total_count"), :>=, 3

    get "/public/events?page=2&per_page=1", as: :json
    assert_response :success
    second_page = response.parsed_body
    assert_equal [ second.id ], second_page.fetch("data").map { |event| event.fetch("id") }
  end

  test "public event list breaks equal publish timestamps by descending event ID" do
    published_at = Time.current.change(usec: 0)
    first = create_public_event("Tie order A", published_at:)
    second = create_public_event("Tie order B", published_at:)

    get "/public/events?per_page=100", as: :json

    assert_response :success
    tied_ids = response.parsed_body.fetch("data")
      .select { |event| [ first.id, second.id ].include?(event.fetch("id")) }
      .map { |event| event.fetch("id") }
    assert_equal [ first.id, second.id ].sort.reverse, tied_ids
  end

  test "public event list caps page size and returns metadata for an empty page" do
    get "/public/events?per_page=1000", as: :json
    assert_response :success
    assert_equal 100, response.parsed_body.dig("pagination", "per_page")
    assert_operator response.parsed_body.fetch("data").length, :<=, 100

    total_count = response.parsed_body.dig("pagination", "total_count")
    get "/public/events?page=999&per_page=1", as: :json
    assert_response :success
    assert_empty response.parsed_body.fetch("data")
    assert_equal total_count, response.parsed_body.dig("pagination", "total_count")
  end

  test "public event discovery applies text and followable filters before pagination" do
    @event.update!(title: "Addis Jazz Festival")
    @event.event_categories.find_or_create_by!(category: events_categories(:music))
    date = @event.event_dates.first
    date.update!(venue: events_venues(:grand_palace), starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours)
    artist = events_artists(:teddy)
    @event.event_participants.create!(
      event_date: date, artist_id: artist.id, name: artist.name, type: "performer", display_order: 1
    )

    other = create_public_event("Dire Dawa Jazz", published_at: Time.current)
    other_date = other.event_dates.create!(
      venue: events_venues(:red_hall), starts_at: 2.days.from_now, ends_at: 2.days.from_now + 3.hours,
      status: "scheduled"
    )
    other.event_participants.create!(
      event_date: other_date, artist_id: events_artists(:haleluya).id,
      name: "Haleluya", type: "performer", display_order: 1
    )

    filters = {
      q: "jazz", category: "music", city: "addis ababa",
      date_from: 1.day.from_now.iso8601, date_to: 4.days.from_now.iso8601,
      organization_id: @event.organization_id, venue_id: events_venues(:grand_palace).id,
      artist_id: artist.id
    }
    get "/public/events?#{Rack::Utils.build_query(filters)}", as: :json

    assert_response :success
    ids = response.parsed_body.fetch("data").map { |event| event.fetch("id") }
    assert_includes ids, @event.id
    refute_includes ids, other.id
  end

  test "artist and date filters must refer to a compatible event date" do
    event = create_public_event("Artist date mismatch", published_at: Time.current)
    matching_venue_date = event.event_dates.create!(
      venue: events_venues(:grand_palace), starts_at: 2.days.from_now,
      ends_at: 2.days.from_now + 3.hours, status: "scheduled"
    )
    other_venue_date = event.event_dates.create!(
      venue: events_venues(:red_hall), starts_at: 2.days.from_now,
      ends_at: 2.days.from_now + 3.hours, status: "scheduled"
    )
    artist = events_artists(:teddy)
    event.event_participants.create!(
      event_date: other_venue_date, artist_id: artist.id, name: artist.name,
      type: "performer", display_order: 1
    )

    get "/public/events?venue_id=#{events_venues(:grand_palace).id}&artist_id=#{artist.id}", as: :json

    assert_response :success
    ids = response.parsed_body.fetch("data").map { |row| row.fetch("id") }
    refute_includes ids, event.id
    assert_nil matching_venue_date.event_participants.find_by(artist_id: artist.id)
  end

  test "organization discovery includes active collaborators but excludes pending invitations" do
    collaborator = organizations_organizations(:three)
    active_event = create_public_event("Active collaborator event", published_at: Time.current)
    active_event.event_organizations.create!(
      organization: collaborator, type: "promoter", role: "collaborator", status: "active"
    )
    pending_event = create_public_event("Pending collaborator event", published_at: Time.current)
    pending_event.event_organizations.create!(
      organization: collaborator, type: "promoter", role: "collaborator", status: "pending"
    )

    get "/public/events?organization_id=#{collaborator.id}", as: :json

    assert_response :success
    ids = response.parsed_body.fetch("data").map { |row| row.fetch("id") }
    assert_includes ids, active_event.id
    refute_includes ids, pending_event.id
  end

  test "public event search requires explicit currency for price operations" do
    get "/public/events?min_price_minor=100", as: :json

    assert_response :unprocessable_entity
    assert_equal "invalid_public_event_filter", response.parsed_body["code"]

    get "/public/events?sort=price_asc", as: :json

    assert_response :unprocessable_entity
    assert_equal "invalid_public_event_filter", response.parsed_body["code"]
  end

  test "public event search rejects a price bound outside database integer range" do
    get "/public/events?currency=ETB&min_price_minor=99999999999999999999", as: :json

    assert_response :unprocessable_entity
    assert_equal "invalid_public_event_filter", response.parsed_body["code"]
  end

  test "public event search rejects inverted price bounds" do
    get "/public/events?currency=ETB&min_price_minor=200&max_price_minor=100", as: :json

    assert_response :unprocessable_entity
    assert_equal "invalid_public_event_filter", response.parsed_body["code"]
  end

  test "public event search rejects unsupported sort values" do
    get "/public/events?sort=database_column", as: :json

    assert_response :unprocessable_entity
    assert_equal "invalid_public_event_filter", response.parsed_body["code"]
  end

  test "public event search rejects malformed timestamps and followable IDs" do
    [
      { date_from: "not-a-timestamp" },
      { organization_id: "not-a-uuid" }
    ].each do |filters|
      get "/public/events?#{Rack::Utils.build_query(filters)}", as: :json

      assert_response :unprocessable_entity
      assert_equal "invalid_public_event_filter", response.parsed_body["code"]
    end
  end

  test "price filtering and ordering use only the explicitly selected currency" do
    cheaper = create_public_event("USD cheaper", published_at: Time.current)
    tied = create_public_event("USD tied", published_at: Time.current)
    expensive = create_public_event("USD expensive", published_at: Time.current)
    outside_range = create_public_event("USD outside range", published_at: Time.current)
    [ cheaper, tied, expensive, outside_range ].each do |event|
      starts_at = 4.days.from_now
      event.event_dates.create!(starts_at:, ends_at: starts_at + 2.hours, status: "scheduled")
    end
    create_active_ticket_product(event: cheaper, currency: "USD", amount_minor: 500)
    create_active_ticket_product(event: tied, currency: "USD", amount_minor: 500)
    create_active_ticket_product(event: expensive, currency: "USD", amount_minor: 1_500)
    create_active_ticket_product(event: outside_range, currency: "USD", amount_minor: 2_500)
    create_active_ticket_product(event: cheaper, currency: "ETB", amount_minor: 10)

    get "/public/events?currency=USD&min_price_minor=400&max_price_minor=2000&sort=price_asc&per_page=100", as: :json

    assert_response :success
    events = response.parsed_body.fetch("data")
    selected = events.select do |event|
      [ cheaper.id, tied.id, expensive.id, outside_range.id ].include?(event.fetch("id"))
    end
    assert_equal [ tied.id, cheaper.id, expensive.id ], selected.map { |event| event.fetch("id") }
    assert_equal 500, selected.first.fetch("price_from_minor")
    assert_equal "USD", selected.first.fetch("price_from_currency")
    refute_includes events.map { |event| event.fetch("id") }, outside_range.id
  end

  test "public event discovery sorts by the soonest matching event date" do
    soonest = create_public_event("Soonest event", published_at: 2.days.ago)
    later = create_public_event("Later event", published_at: 1.hour.from_now)
    [ [ soonest, 1.day.from_now ], [ later, 5.days.from_now ] ].each do |event, starts_at|
      event.event_dates.create!(starts_at:, ends_at: starts_at + 2.hours, status: "scheduled")
    end

    get "/public/events?sort=soonest&per_page=100", as: :json

    assert_response :success
    ids = response.parsed_body.fetch("data").map { |event| event.fetch("id") }
    assert_operator ids.index(soonest.id), :<, ids.index(later.id)
  end

  test "event detail returns only a bounded upcoming date preview" do
    8.times do |index|
      starts_at = (index + 3).days.from_now
      @event.event_dates.create!(
        starts_at:, ends_at: starts_at + 2.hours, status: "scheduled", name: "Session #{index}"
      )
    end

    get "/public/events/#{@event.slug}", as: :json

    assert_response :success
    body = response.parsed_body.fetch("data")
    preview = body["event_dates_preview"]
    assert_kind_of Array, preview
    return unless preview.is_a?(Array)

    assert_operator preview.length, :<=, 7
    refute body.key?("event_dates")
    assert_equal "/public/events/#{@event.slug}/dates", body.fetch("event_dates_url")
  end

  test "public event dates default to upcoming rows and allow paginated history ranges" do
    past = @event.event_dates.create!(
      starts_at: 3.days.ago, ends_at: 3.days.ago + 2.hours, status: "completed", name: "Past show"
    )

    get "/public/events/#{@event.slug}/dates?page=1&per_page=2", as: :json

    assert_response :success
    return unless response.successful?

    body = response.parsed_body
    refute_includes body.fetch("data").map { |date| date.fetch("id") }, past.id
    assert_equal 2, body.dig("pagination", "per_page")

    get "/public/events/#{@event.slug}/dates?per_page=1000", as: :json

    assert_response :success
    assert_equal 100, response.parsed_body.dig("pagination", "per_page")

    get "/public/events/#{@event.slug}/dates?from=#{5.days.ago.iso8601}&to=#{1.day.ago.iso8601}", as: :json

    assert_response :success
    return unless response.successful?

    assert_includes response.parsed_body.fetch("data").map { |date| date.fetch("id") }, past.id
  end

  test "public event dates reject malformed timestamps and inverted ranges" do
    get "/public/events/#{@event.slug}/dates?from=not-a-timestamp", as: :json

    assert_response :unprocessable_entity
    assert_equal "invalid_public_event_filter", response.parsed_body.fetch("code")

    get "/public/events/#{@event.slug}/dates?from=#{2.days.from_now.iso8601}&to=#{1.day.from_now.iso8601}", as: :json

    assert_response :unprocessable_entity
    assert_equal "invalid_public_event_filter", response.parsed_body.fetch("code")
  end

  test "public recurrence dates expose a safe series ID without internal source keys" do
    rule = @event.create_recurrence_rule!(
      rrule: "FREQ=WEEKLY;COUNT=2", timezone: @event.timezone,
      dtstart_local: 1.day.from_now, duration_seconds: 2.hours.to_i, active: true
    )
    starts_at = 4.days.from_now
    @event.event_dates.create!(
      starts_at:, ends_at: starts_at + 2.hours, status: "scheduled",
      source_key: "recurrence-#{rule.id}-#{starts_at.to_i}"
    )

    get "/public/events/#{@event.slug}", as: :json

    assert_response :success
    body = response.parsed_body.fetch("data")
    assert_equal true, body["is_recurring"]
    preview = body["event_dates_preview"]
    assert_kind_of Array, preview
    return unless preview.is_a?(Array)

    recurring_date = preview.find { |date| date["series_id"] == rule.id }
    refute_nil recurring_date
    refute recurring_date.key?("source_key")
    refute body.key?("recurrence_rule")
  end

  test "public event list exposes the minimum active ticket price in event currency" do
    ticket_product = create_active_ticket_product(amount_minor: 30_000)

    product = Catalog::EventProduct.create!(
      event: @event, name: "List price product", type: "merchandise", status: "active",
      inventory_mode: "unlimited", schedule_change_refund_policy: "full_or_partial"
    )
    Catalog::ProductPrice.create!(event_product: product, type: "base", currency: "ETB",
                                  amount_minor: 2_500, active_from: 1.hour.ago)
    Catalog::ProductPrice.create!(event_product: product, type: "base", currency: "USD",
                                  amount_minor: 10, active_from: 1.hour.ago)
    cheaper = Catalog::EventProduct.create!(
      event: @event, name: "Cheaper list price product", type: "merchandise", status: "active",
      inventory_mode: "unlimited", schedule_change_refund_policy: "full_or_partial"
    )
    Catalog::ProductPrice.create!(event_product: cheaper, type: "base", currency: "ETB",
                                  amount_minor: 1_900, active_from: 1.hour.ago)

    get "/public/events", as: :json

    assert_response :success
    event = response.parsed_body.fetch("data").find { |item| item["id"] == @event.id }
    assert_equal 30_000, event.fetch("price_from_minor"), ticket_product.name
  end

  test "public event card price ignores gated ticket offers" do
    create_active_ticket_product(amount_minor: 50_000)
    create_active_ticket_product(amount_minor: 5_000, audience: "access_code")

    get "/public/events", as: :json

    assert_response :success
    event = response.parsed_body.fetch("data").find { |item| item["id"] == @event.id }
    assert_equal 50_000, event.fetch("price_from_minor")
  end

  test "event cards skip cancelled dates when selecting the next event date" do
    cancelled_starts_at = 1.day.from_now
    @event.event_dates.create!(
      starts_at: cancelled_starts_at, ends_at: cancelled_starts_at + 2.hours,
      status: "cancelled", name: "Cancelled date"
    )

    get "/public/events", as: :json

    assert_response :success
    event = response.parsed_body.fetch("data").find { |item| item.fetch("id") == @event.id }
    assert_equal "Main show", event.dig("next_event_date", "name")
  end

  test "featured discovery does not fall back to organic events when featured resolution fails" do
    failure = Core::BusinessError.new(
      "internal featured query failure", code: "internal_failure", status: :unprocessable_entity
    )
    Marketing::FeaturedPlacements::PublicQuery.stubs(:call)
      .returns(Core::BaseService::Result.failure(failure))

    get "/public/events?featured=true", as: :json

    assert_response :service_unavailable
    assert_equal "featured_events_unavailable", response.parsed_body.fetch("code")
    refute response.parsed_body.key?("data")
    refute_includes response.body, "internal featured query failure"
  end

  test "private draft events are excluded from public discovery" do
    get "/public/events", as: :json
    bodies = JSON.parse(response.body).dig("data")
    refute bodies.any? { |e| e["id"] == events_events(:draft_concert).id }
  end

  test "cancelled and completed event records remain hidden from discovery" do
    cancelled = create_public_event("Cancelled public", published_at: Time.current, status: "cancelled")
    completed = create_public_event("Completed public", published_at: Time.current, status: "completed")

    get "/public/events", as: :json

    assert_response :success
    ids = response.parsed_body.fetch("data").map { |event| event.fetch("id") }
    refute_includes ids, cancelled.id
    refute_includes ids, completed.id
  end

  test "public event detail exposes only attendee-safe fields" do
    route = Rails.application.routes.recognize_path("/public/events/#{@event.slug}", method: :get)
    assert_equal "public/events", route.fetch(:controller)
    assert_equal "show", route.fetch(:action)

    get "/public/events/#{@event.slug}", as: :json
    assert_response :success
    body = JSON.parse(response.body).dig("data")
    assert_equal @event.id, body["id"]
    assert_includes body.keys, "title"
    assert_equal "Music", body.dig("categories", 0, "name")
    assert_equal "Grand Palace", body.dig("event_dates_preview", 0, "venue", "name")
    assert_equal "Addis Ababa", body.dig("event_dates_preview", 0, "venue", "city")
    refute body.key?("event_dates")
    assert body.dig("event_media", 0, "file", "medium").present?
    assert_equal @event.organization.name, body.dig("organization", "name")
    refute body.dig("event_setting", "config").key?("event_type")
    refute body.dig("event_setting", "config").key?("allow_waitlist")
    refute body.dig("event_setting", "config").key?("internal_flag")
    refute_includes body.keys, "cancelled_at"
    refute_includes body.keys, "internal_notes"
  end

  test "private event is not directly lookupable by unauthenticated user" do
    get "/public/events/#{events_events(:draft_concert).slug}", as: :json
    assert_response :not_found
  end

  test "old RSVP routes are retired and admission selection is routed" do
    [
      "/public/events/#{@event.slug}/rsvp",
      "/public/events/#{@event.slug}/rsvp/request_otp",
      "/registrations/#{SecureRandom.uuid}/enqueue_waitlist",
      "/registrations/#{SecureRandom.uuid}/accept_waitlist_offer"
    ].each do |path|
      assert_raises(ActionController::RoutingError) do
        Rails.application.routes.recognize_path(path, method: :post)
      end
    end

    route = Rails.application.routes.recognize_path(
      "/public/events/#{@event.slug}/admission_selections", method: :post
    )
    assert_equal "orders/admission_selections", route.fetch(:controller)
    assert_equal "create", route.fetch(:action)
  end

  private

  def create_public_event(title, published_at:, status: "published")
    Events::Event.create!(
      organization: @event.organization,
      created_by: core_users(:super_admin),
      title:,
      slug: "#{title.parameterize}-#{SecureRandom.hex(3)}",
      status:,
      visibility: "public",
      timezone: "Africa/Addis_Ababa",
      currency: "ETB",
      published_at:
    )
  end

  def create_active_ticket_product(amount_minor:, audience: "public", event: @event, currency: "ETB")
    product = Catalog::Products::CreateDraft.call(
      event:,
      actor: core_users(:super_admin),
      product_attributes: { name: "List ticket", type: "ticket" },
      ticket_type_attributes: {
        audience:, approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
      },
      price_attributes: { currency:, amount_minor:, active_from: 1.hour.ago },
      inventory_configuration: { mode: "unlimited" }
    ).value
    product.product_accesses.create!(event_date: event.event_dates.first, type: "venue", usage_limit: nil)
    Catalog::Products::Activate.call(product:, actor: core_users(:super_admin)).value
  end
end
