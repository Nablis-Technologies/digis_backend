# frozen_string_literal: true

require "test_helper"

module Catalog
  class ProductAccessZoneTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @date = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                        ends_at: 1.day.from_now + 4.hours)
      @product = Catalog::EventProduct.create!(event: @event, name: "Test Pass",
                                                type: "merchandise", status: "draft",
                                                inventory_mode: "unlimited")
      @zone = Events::AccessZone.create!(event: @event, code: "MAIN", name: "Main Gate",
                                         type: "venue", sort_order: 0)
    end

    test "venue access can have a zone grant" do
      access = Catalog::ProductAccess.create!(
        event_product: @product,
        event_date: @date,
        type: "venue"
      )
      grant = Catalog::ProductAccessZone.new(
        product_access: access,
        access_zone: @zone
      )
      assert grant.valid?, grant.errors.full_messages.join(", ")
    end

    test "stream access rejects zone grants" do
      access = Catalog::ProductAccess.create!(
        event_product: @product,
        event_date: @date,
        type: "stream",
        required_access_protection: "public"
      )
      grant = Catalog::ProductAccessZone.new(
        product_access: access,
        access_zone: @zone
      )
      refute grant.valid?
    end

    test "zone must belong to same event as product" do
      other_event = events_events(:draft_concert)
      other_zone = Events::AccessZone.create!(event: other_event, code: "VIP",
                                              name: "VIP Gate", type: "venue", sort_order: 0)
      access = Catalog::ProductAccess.create!(
        event_product: @product,
        event_date: @date,
        type: "venue"
      )
      grant = Catalog::ProductAccessZone.new(
        product_access: access,
        access_zone: other_zone
      )
      refute grant.valid?
    end

    test "zone type must match access type" do
      parking_zone = Events::AccessZone.create!(event: @event, code: "PARK",
                                                name: "Parking Lot", type: "parking",
                                                sort_order: 0)
      access = Catalog::ProductAccess.create!(
        event_product: @product,
        event_date: @date,
        type: "venue"
      )
      grant = Catalog::ProductAccessZone.new(
        product_access: access,
        access_zone: parking_zone
      )
      refute grant.valid?
    end

    test "unique constraint on product_access_id and access_zone_id" do
      access = Catalog::ProductAccess.create!(
        event_product: @product,
        event_date: @date,
        type: "venue"
      )
      Catalog::ProductAccessZone.create!(product_access: access, access_zone: @zone)
      duplicate = Catalog::ProductAccessZone.new(
        product_access: access,
        access_zone: @zone
      )
      refute duplicate.valid?
    end
  end
end
