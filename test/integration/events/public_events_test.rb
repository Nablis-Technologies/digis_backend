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
    assert_equal "Main show", event.dig("event_dates", 0, "name")
    assert_equal "Grand Palace", event.dig("event_dates", 0, "venue", "name")
    assert_equal "Addis Ababa", event.dig("event_dates", 0, "venue", "city")
    assert event.dig("event_media", 0, "file", "medium").present?
    refute event.dig("event_setting", "config").key?("internal_flag")
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
    get "/public/events/#{@event.slug}", as: :json
    assert_response :success
    body = JSON.parse(response.body).dig("data")
    assert_equal @event.id, body["id"]
    assert_includes body.keys, "title"
    assert_equal "Music", body.dig("categories", 0, "name")
    assert_equal "Grand Palace", body.dig("event_dates", 0, "venue", "name")
    assert_equal "Addis Ababa", body.dig("event_dates", 0, "venue", "city")
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

  def create_active_ticket_product(amount_minor:, audience: "public")
    product = Catalog::Products::CreateDraft.call(
      event: @event,
      actor: core_users(:super_admin),
      product_attributes: { name: "List ticket", type: "ticket" },
      ticket_type_attributes: {
        audience:, approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
      },
      price_attributes: { currency: "ETB", amount_minor:, active_from: 1.hour.ago },
      inventory_configuration: { mode: "unlimited" }
    ).value
    product.product_accesses.create!(event_date: @event.event_dates.first, type: "venue", usage_limit: nil)
    Catalog::Products::Activate.call(product:, actor: core_users(:super_admin)).value
  end
end
