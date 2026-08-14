# frozen_string_literal: true

require "test_helper"

module Catalog
  module Accesses
    class ReplaceTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @date = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                          ends_at: 1.day.from_now + 4.hours)
        @product = Catalog::EventProduct.create!(event: @event, name: "Festival Pass",
                                                  type: "merchandise", status: "draft",
                                                  inventory_mode: "unlimited")
      end

      test "replaces accesses for a draft product" do
        initial_schedule_version = @event.reload.schedule_version
        result = Replace.call(
          product: @product,
          accesses: [
            { event_date_id: @date.id, type: "venue" }
          ]
        )

        assert result.success?, result.error&.message
        assert_equal 1, result.value.product_accesses.count
        access = result.value.product_accesses.first
        assert_equal "venue", access.type
        assert_equal @date.id, access.event_date_id
        assert_equal initial_schedule_version + 1, @event.reload.schedule_version
      end

      test "rejects active product" do
        @product = Catalog::EventProduct.create!(event: @event, name: "Active Pass",
                                                  type: "merchandise", status: "active",
                                                  inventory_mode: "unlimited")

        result = Replace.call(
          product: @product,
          accesses: [ { event_date_id: @date.id, type: "venue" } ]
        )

        assert result.failure?
        assert_match(/draft/i, result.error.message)
      end

      test "rejects retired product" do
        @product = Catalog::EventProduct.create!(event: @event, name: "Retired Pass",
                                                  type: "merchandise", status: "retired",
                                                  inventory_mode: "unlimited")

        result = Replace.call(
          product: @product,
          accesses: [ { event_date_id: @date.id, type: "venue" } ]
        )

        assert result.failure?
        assert_match(/draft/i, result.error.message)
      end

      test "atomically replaces existing accesses" do
        Replace.call(
          product: @product,
          accesses: [ { event_date_id: @date.id, type: "venue" } ]
        )

        result = Replace.call(
          product: @product,
          accesses: [
            { event_date_id: @date.id, type: "venue" },
            { event_date_id: @date.id, type: "parking" }
          ]
        )

        assert result.success?, result.error&.message
        assert_equal 2, result.value.product_accesses.count
      end

      test "rejects invalid date that does not belong to event" do
        other_event = events_events(:draft_concert)
        other_date = Events::EventDate.create!(
          event: other_event,
          starts_at: 1.day.from_now,
          ends_at: 1.day.from_now + 4.hours
        )

        result = Replace.call(
          product: @product,
          accesses: [ { event_date_id: other_date.id, type: "venue" } ]
        )

        assert result.failure?
      end

      test "rejects stream access without protection" do
        result = Replace.call(
          product: @product,
          accesses: [ { event_date_id: @date.id, type: "stream" } ]
        )

        assert result.failure?
      end

      test "rejects duplicate access entries in a single request" do
        result = Replace.call(
          product: @product,
          accesses: [
            { event_date_id: @date.id, type: "venue" },
            { event_date_id: @date.id, type: "venue" }
          ]
        )

        assert result.failure?
        assert_match(/duplicate/i, result.error.message)
      end

      test "rejects replacement when a held inventory reservation exists" do
        inv = Catalog::ProductInventory.create!(event_product: @product, capacity: 5, held_count: 1)
        Catalog::InventoryReservation.create!(
          product_inventory: inv,
          reservation_group_id: SecureRandom.uuid,
          quantity: 1,
          admissions_per_unit: 1,
          status: "held",
          expires_at: 10.minutes.from_now,
          request_fingerprint: Digest::SHA256.hexdigest("test")
        )

        result = Replace.call(
          product: @product,
          accesses: [ { event_date_id: @date.id, type: "venue" } ]
        )

        assert result.failure?
        assert_match(/immutable/i, result.error.message)
      end

      test "rejects replacement when venue reservations exist" do
        Catalog::VenueCapacityReservation.create!(
          event_product: @product,
          event_date: @date,
          reservation_group_id: SecureRandom.uuid,
          quantity_people: 2,
          status: "held",
          expires_at: 10.minutes.from_now,
          request_fingerprint: Digest::SHA256.hexdigest("test")
        )

        result = Replace.call(
          product: @product,
          accesses: [ { event_date_id: @date.id, type: "venue" } ]
        )

        assert result.failure?
        assert_match(/immutable/i, result.error.message)
      end
    end
  end
end
