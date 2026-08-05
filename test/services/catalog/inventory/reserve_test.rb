# frozen_string_literal: true

require "test_helper"

module Catalog
  module Inventory
    class ReserveTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @date_one = create_event_date(starts_at: 1.day.from_now)
        @date_two = create_event_date(starts_at: 3.days.from_now)
        @expires_at = 10.minutes.from_now.change(usec: 0)
      end

      test "event-wide inventory reserves its pool and every requested venue date exactly once" do
        product = create_product(mode: "event_wide")
        inventory = create_inventory(product:, capacity: 10)

        result = reserve(
          product:,
          event_date_ids: [ @date_two.id, @date_one.id, @date_one.id ],
          quantity: 2,
          admissions: 3
        )

        assert result.success?, result.error&.message
        assert_equal 2, inventory.reload.held_count
        assert_equal 6, @date_one.reload.held_venue_count
        assert_equal 6, @date_two.reload.held_venue_count
        assert_equal 1, Catalog::InventoryReservation.by_group(result_group(result)).count
        assert_equal 2, Catalog::VenueCapacityReservation.by_group(result_group(result)).count
      end

      test "unlimited inventory still creates venue holds for requested dates" do
        product = create_product(mode: "unlimited")
        group_id = SecureRandom.uuid

        result = reserve(
          product:,
          event_date_ids: [ @date_one.id ],
          quantity: 4,
          admissions: 2,
          group_id:
        )

        assert result.success?, result.error&.message
        assert_empty Catalog::InventoryReservation.by_group(group_id)
        venue_reservation = Catalog::VenueCapacityReservation.by_group(group_id).sole
        assert_equal 8, venue_reservation.quantity_people
        assert_equal 8, @date_one.reload.held_venue_count
      end

      test "stream-only selection does not consume physical venue capacity" do
        product = create_product(mode: "unlimited")

        result = reserve(
          product:,
          event_date_ids: [ @date_one.id ],
          venue_event_date_ids: [],
          quantity: 4,
          admissions: 2
        )

        assert result.success?, result.error&.message
        assert_empty Catalog::VenueCapacityReservation.by_group(result_group(result))
        assert_equal 0, @date_one.reload.held_venue_count
      end

      test "combined mode fails atomically when any requested date pool is missing" do
        product = create_product(mode: "event_wide_and_per_date")
        global = create_inventory(product:, capacity: 10)
        dated = create_inventory(product:, event_date: @date_one, capacity: 10)

        result = reserve(
          product:,
          event_date_ids: [ @date_one.id, @date_two.id ],
          quantity: 2
        )

        assert result.failure?
        assert_equal 0, global.reload.held_count
        assert_equal 0, dated.reload.held_count
        assert_equal 0, @date_one.reload.held_venue_count
        assert_equal 0, @date_two.reload.held_venue_count
        product_reservations = Catalog::InventoryReservation
          .joins(:product_inventory)
          .where(catalog_product_inventories: { event_product_id: product.id })
        assert_empty product_reservations
        assert_empty Catalog::VenueCapacityReservation.where(event_product: product)
      end

      test "per-date mode updates every requested pool by the exact package quantity" do
        product = create_product(mode: "per_date")
        first_inventory = create_inventory(product:, event_date: @date_one, capacity: 10)
        second_inventory = create_inventory(product:, event_date: @date_two, capacity: 10)

        result = reserve(
          product:,
          event_date_ids: [ @date_two.id, @date_one.id ],
          quantity: 3,
          admissions: 2
        )

        assert result.success?, result.error&.message
        assert_equal 3, first_inventory.reload.held_count
        assert_equal 3, second_inventory.reload.held_count
        assert_equal 6, @date_one.reload.held_venue_count
        assert_equal 6, @date_two.reload.held_venue_count
      end

      test "identical replay returns current group without changing counters" do
        product = create_product(mode: "event_wide")
        inventory = create_inventory(product:, capacity: 10)
        group_id = SecureRandom.uuid
        command = lambda do
          reserve(
            product:,
            event_date_ids: [ @date_one.id ],
            quantity: 2,
            admissions: 2,
            group_id:
          )
        end

        first = command.call
        second = command.call

        assert first.success?
        assert second.success?
        assert_equal first.value.map(&:id).sort, second.value.map(&:id).sort
        assert_equal 2, inventory.reload.held_count
        assert_equal 4, @date_one.reload.held_venue_count
        assert_equal 2, second.value.size
      end

      test "reused group with a different request fails without mutation" do
        product = create_product(mode: "event_wide")
        inventory = create_inventory(product:, capacity: 10)
        group_id = SecureRandom.uuid
        original = reserve(
          product:,
          event_date_ids: [ @date_one.id ],
          quantity: 2,
          group_id:
        )

        replay = reserve(
          product:,
          event_date_ids: [ @date_one.id ],
          quantity: 3,
          group_id:
        )

        assert original.success?
        assert replay.failure?
        assert_equal 2, inventory.reload.held_count
        assert_equal 2, @date_one.reload.held_venue_count
        assert_equal 2, original.value.size
      end

      test "reused group on another product fails without reserving the second product" do
        first_product = create_product(mode: "event_wide", name: "First product")
        first_inventory = create_inventory(product: first_product, capacity: 10)
        second_product = create_product(mode: "event_wide", name: "Second product")
        second_inventory = create_inventory(product: second_product, capacity: 10)
        group_id = SecureRandom.uuid

        assert reserve(
          product: first_product,
          event_date_ids: [ @date_one.id ],
          quantity: 2,
          group_id:
        ).success?

        replay = reserve(
          product: second_product,
          event_date_ids: [ @date_one.id ],
          quantity: 2,
          group_id:
        )

        assert replay.failure?
        assert_equal 2, first_inventory.reload.held_count
        assert_equal 0, second_inventory.reload.held_count
        assert_equal 2, @date_one.reload.held_venue_count
      end

      test "fingerprint is stable for reordered duplicate date ids and changes with owner identity" do
        product = create_product(mode: "unlimited")
        owner_one = Struct.new(:id).new(SecureRandom.uuid)
        owner_two = Struct.new(:id).new(SecureRandom.uuid)

        first = ReservationRequest.new(
          product:,
          event_date_ids: [ @date_two.id, @date_one.id, @date_one.id ],
          package_quantity: 2,
          admissions_per_unit: 3,
          owner: owner_one,
          expires_at: @expires_at
        )
        reordered = ReservationRequest.new(
          product:,
          event_date_ids: [ @date_one.id, @date_two.id ],
          package_quantity: 2,
          admissions_per_unit: 3,
          owner: owner_one,
          expires_at: @expires_at
        )
        other_owner = ReservationRequest.new(
          product:,
          event_date_ids: [ @date_one.id, @date_two.id ],
          package_quantity: 2,
          admissions_per_unit: 3,
          owner: owner_two,
          expires_at: @expires_at
        )

        assert_equal first.fingerprint, reordered.fingerprint
        refute_equal first.fingerprint, other_owner.fingerprint
        assert_equal 64, first.fingerprint.length
      end

      test "capacity failure leaves product and venue counters unchanged" do
        product = create_product(mode: "event_wide")
        inventory = create_inventory(product:, capacity: 1)

        result = reserve(
          product:,
          event_date_ids: [ @date_one.id ],
          quantity: 2
        )

        assert result.failure?
        assert_equal 0, inventory.reload.held_count
        assert_equal 0, @date_one.reload.held_venue_count
      end

      private

      def reserve(product:, event_date_ids: [], venue_event_date_ids: event_date_ids,
        quantity:, admissions: 1, group_id: SecureRandom.uuid)
        @last_group_id = group_id
        Reserve.call(
          product:,
          event_date_ids:,
          venue_event_date_ids:,
          package_quantity: quantity,
          admissions_per_unit: admissions,
          reservation_group_id: group_id,
          expires_at: @expires_at
        )
      end

      def result_group(_result)
        @last_group_id
      end

      def create_product(mode:, name: "Festival Pass")
        Catalog::EventProduct.create!(
          event: @event,
          name:,
          type: "merchandise",
          status: "active",
          inventory_mode: mode
        )
      end

      def create_inventory(product:, capacity:, event_date: nil)
        Catalog::ProductInventory.create!(
          event_product: product,
          event_date:,
          capacity:
        )
      end

      def create_event_date(starts_at:)
        Events::EventDate.create!(
          event: @event,
          starts_at:,
          ends_at: starts_at + 4.hours,
          venue_capacity: 100
        )
      end
    end
  end
end
