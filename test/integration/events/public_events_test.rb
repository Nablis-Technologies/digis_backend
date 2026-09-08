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
    @event.event_dates.first.update!(venue: events_venues(:grand_palace), name: "Main show")
    @event.event_setting.update!(config: { allow_waitlist: true, public_guest_limit: 10, internal_flag: true })
    Events::Publish.call(event: @event, actor: core_users(:super_admin),
                         idempotency_key: SecureRandom.uuid)
  end

  test "published public events are discoverable without auth" do
    get "/public/events", as: :json
    assert_response :success
    bodies = JSON.parse(response.body).dig("data")
    event = bodies.find { |item| item["id"] == @event.id }
    assert event
    assert_equal "10", event.dig("event_setting", "config", "public_guest_limit").to_s
    assert_equal "Main show", event.dig("event_dates", 0, "name")
    assert_equal "Grand Palace", event.dig("event_dates", 0, "venue", "name")
    assert_equal "Addis Ababa", event.dig("event_dates", 0, "venue", "city")
    assert event.dig("event_media", 0, "file", "medium").present?
    refute event.dig("event_setting", "config").key?("internal_flag")
  end

  test "public event list exposes the minimum active price in event currency" do
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
    assert_equal 1_900, event.fetch("price_from_minor")
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
    assert_equal "Music", body.dig("categories", 0, "name")
    assert_equal "Grand Palace", body.dig("event_dates", 0, "venue", "name")
    assert_equal "Addis Ababa", body.dig("event_dates", 0, "venue", "city")
    assert body.dig("event_media", 0, "file", "medium").present?
    assert_equal @event.organization.name, body.dig("organization", "name")
    assert_equal true, body.dig("event_setting", "config", "allow_waitlist")
    refute body.dig("event_setting", "config").key?("internal_flag")
    refute_includes body.keys, "cancelled_at"
    refute_includes body.keys, "internal_notes"
  end

  test "private event is not directly lookupable by unauthenticated user" do
    get "/public/events/#{events_events(:draft_concert).slug}", as: :json
    assert_response :not_found
  end
end
