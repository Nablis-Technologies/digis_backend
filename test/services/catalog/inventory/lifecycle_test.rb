# frozen_string_literal: true

require "test_helper"

module Catalog
  module Inventory
    class LifecycleTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @event_date = Events::EventDate.create!(
          event: @event,
          starts_at: 1.day.from_now,
          ends_at: 2.days.from_now,
          venue_capacity: 100
        )
        @product = Catalog::EventProduct.create!(
          event: @event,
          name: "Festival Pass",
          type: "merchandise",
          status: "active",
          inventory_mode: "event_wide"
        )
        @inventory = Catalog::ProductInventory.create!(
          event_product: @product,
          capacity: 20
        )
        @reservation_group_id = SecureRandom.uuid
        @expires_at = 10.minutes.from_now.change(usec: 0)
        reserve_group!
      end

      test "commit transitions held and processing rows in both reservation tables" do
        inventory_reservation.update!(status: "processing")
        venue_reservation.update!(status: "processing")

        result = Commit.call(reservation_group_id: @reservation_group_id)

        assert result.success?, result.error&.message
        assert result.value.all?(&:committed?)
        assert_equal 0, @inventory.reload.held_count
        assert_equal 3, @inventory.sold_count
        assert_equal 0, @event_date.reload.held_venue_count
        assert_equal 6, @event_date.issued_venue_count
      end

      test "commit replay is idempotent across both reservation tables" do
        first = Commit.call(reservation_group_id: @reservation_group_id)
        second = Commit.call(reservation_group_id: @reservation_group_id)

        assert first.success?
        assert second.success?
        assert_equal first.value.map(&:id).sort, second.value.map(&:id).sort
        assert_equal 0, @inventory.reload.held_count
        assert_equal 3, @inventory.sold_count
        assert_equal 0, @event_date.reload.held_venue_count
        assert_equal 6, @event_date.issued_venue_count
      end

      test "release transitions held and processing rows and decrements exact counters" do
        inventory_reservation.update!(status: "processing")
        venue_reservation.update!(status: "processing")

        result = Release.call(reservation_group_id: @reservation_group_id)

        assert result.success?, result.error&.message
        assert result.value.all?(&:released?)
        assert_equal 0, @inventory.reload.held_count
        assert_equal 0, @inventory.sold_count
        assert_equal 0, @event_date.reload.held_venue_count
        assert_equal 0, @event_date.issued_venue_count
      end

      test "release replay is idempotent across both reservation tables" do
        first = Release.call(reservation_group_id: @reservation_group_id)
        second = Release.call(reservation_group_id: @reservation_group_id)

        assert first.success?
        assert second.success?
        assert_equal first.value.map(&:id).sort, second.value.map(&:id).sort
        assert_equal 0, @inventory.reload.held_count
        assert_equal 0, @event_date.reload.held_venue_count
      end

      test "mixed target and active states fail without changing counters or rows" do
        inventory_reservation.update_columns(status: "committed", committed_at: Time.current)
        before_inventory = @inventory.reload.attributes.slice("held_count", "sold_count")
        before_date = @event_date.reload.attributes.slice("held_venue_count", "issued_venue_count")

        result = Commit.call(reservation_group_id: @reservation_group_id)

        assert result.failure?
        assert_equal "committed", inventory_reservation.reload.status
        assert_equal "held", venue_reservation.reload.status
        assert_equal before_inventory, @inventory.reload.attributes.slice("held_count", "sold_count")
        assert_equal before_date, @event_date.reload.attributes.slice("held_venue_count", "issued_venue_count")
      end

      test "opposing or expired terminal states fail without mutation" do
        venue_reservation.update_columns(status: "expired", released_at: Time.current)

        commit_result = Commit.call(reservation_group_id: @reservation_group_id)
        release_result = Release.call(reservation_group_id: @reservation_group_id)

        assert commit_result.failure?
        assert release_result.failure?
        assert_equal "held", inventory_reservation.reload.status
        assert_equal "expired", venue_reservation.reload.status
        assert_equal 3, @inventory.reload.held_count
        assert_equal 6, @event_date.reload.held_venue_count
      end

      test "expiry transitions complete processing group from both tables and returns actual row count" do
        inventory_reservation.update!(status: "processing", expires_at: 1.minute.ago)
        venue_reservation.update!(status: "processing", expires_at: 1.minute.ago)

        result = Expire.call

        assert result.success?, result.error&.message
        assert_equal 2, result.value
        assert inventory_reservation.reload.expired?
        assert venue_reservation.reload.expired?
        assert_equal 0, @inventory.reload.held_count
        assert_equal 0, @event_date.reload.held_venue_count
      end

      test "expiry does not release a group while any active row is still valid" do
        inventory_reservation.update!(expires_at: 1.minute.ago)
        venue_reservation.update!(expires_at: 10.minutes.from_now)

        result = Expire.call

        assert result.success?
        assert_equal 0, result.value
        assert inventory_reservation.reload.active?
        assert venue_reservation.reload.active?
        assert_equal 3, @inventory.reload.held_count
        assert_equal 6, @event_date.reload.held_venue_count
      end

      test "expiry discovers unlimited groups from venue reservations" do
        release_current_group!
        unlimited = Catalog::EventProduct.create!(
          event: @event,
          name: "Unlimited pass",
          type: "merchandise",
          status: "active",
          inventory_mode: "unlimited"
        )
        group_id = SecureRandom.uuid
        result = Reserve.call(
          product: unlimited,
          event_date_ids: [ @event_date.id ],
          package_quantity: 2,
          admissions_per_unit: 2,
          reservation_group_id: group_id,
          expires_at: 1.minute.ago
        )
        assert result.success?

        expiry = Expire.call

        assert expiry.success?
        assert_equal 1, expiry.value
        assert Catalog::VenueCapacityReservation.by_group(group_id).sole.expired?
        assert_equal 0, @event_date.reload.held_venue_count
      end

      test "expiry batches complete groups rather than splitting reservation rows" do
        release_current_group!
        @event_date.update!(venue_capacity: Expire::BATCH_SIZE + 10)
        groups = Array.new(Expire::BATCH_SIZE + 1) do
          create_expired_unlimited_group
        end

        result = Expire.call

        assert result.success?
        assert_equal groups.size, result.value
        assert_equal [ "expired" ], Catalog::VenueCapacityReservation.where(reservation_group_id: groups).distinct.pluck(:status)
        assert_equal 0, @event_date.reload.held_venue_count
      end

      test "checked arithmetic rejects drift instead of masking it" do
        release_current_group!
        @inventory.update!(held_count: 0)
        drift_group_id = SecureRandom.uuid
        Catalog::InventoryReservation.create!(
          product_inventory: @inventory,
          reservation_group_id: drift_group_id,
          quantity: 3,
          admissions_per_unit: 2,
          status: "held",
          expires_at: 10.minutes.from_now,
          request_fingerprint: SecureRandom.hex(32)
        )
        Catalog::VenueCapacityReservation.create!(
          event_date: @event_date,
          event_product: @product,
          reservation_group_id: drift_group_id,
          quantity_people: 6,
          status: "held",
          expires_at: 10.minutes.from_now,
          request_fingerprint: SecureRandom.hex(32)
        )

        result = Release.call(reservation_group_id: drift_group_id)

        assert result.failure?
        assert_match(/drift/i, result.error.message)
        assert_equal 0, @inventory.reload.held_count
      end

      test "reconcile detects no discrepancies for clean inventory and venue state" do
        result = Reconcile.call

        assert result.success?
        assert_equal 0, result.value[:total_discrepancies]
      end

      test "reconcile reports venue held-count drift without hiding it" do
        @event_date.update_columns(held_venue_count: 1)

        result = Reconcile.call

        assert result.success?
        discrepancy = result.value[:discrepancies].find do |entry|
          entry[:event_date_id] == @event_date.id && entry[:field] == "held_venue_count"
        end
        assert_not_nil discrepancy
        assert_equal 6, discrepancy[:expected]
        assert_equal 1, discrepancy[:actual]
        assert_equal 1, @event_date.reload.held_venue_count
      end

      test "concurrent reserve requests for the same last unit produce exactly one winner" do
        release_current_group!
        product = Catalog::EventProduct.create!(
          event: @event, name: "Last Unit Race", type: "merchandise",
          status: "active", inventory_mode: "event_wide"
        )
        single_unit = Catalog::ProductInventory.create!(
          event_product: product, capacity: 1
        )
        thread_count = 5
        gate = Queue.new
        start = Queue.new
        results = []

        threads = thread_count.times.map do
          Thread.new do
            gate.push(:ready)
            start.pop
            Reserve.call(
              product:,
              event_date_ids: [],
              package_quantity: 1,
              admissions_per_unit: 1,
              reservation_group_id: SecureRandom.uuid,
              expires_at: 10.minutes.from_now
            )
          end
        end

        thread_count.times { gate.pop }
        thread_count.times { start.push(:go) }
        threads.each { |t| results << t.value }

        successes = results.count(&:success?)
        failures = results.count(&:failure?)

        assert_equal 1, successes, "exactly one thread should win the last unit"
        assert_equal thread_count - 1, failures
        assert_equal 1, single_unit.reload.held_count
        assert_equal 0, single_unit.sold_count
      end

      private

      def reserve_group!
        result = Reserve.call(
          product: @product,
          event_date_ids: [ @event_date.id ],
          package_quantity: 3,
          admissions_per_unit: 2,
          reservation_group_id: @reservation_group_id,
          expires_at: @expires_at
        )
        assert result.success?, result.error&.message
      end

      def inventory_reservation
        Catalog::InventoryReservation.by_group(@reservation_group_id).sole
      end

      def venue_reservation
        Catalog::VenueCapacityReservation.by_group(@reservation_group_id).sole
      end

      def release_current_group!
        result = Release.call(reservation_group_id: @reservation_group_id)
        assert result.success?, result.error&.message
      end

      def create_expired_unlimited_group
        product = Catalog::EventProduct.create!(
          event: @event,
          name: "Unlimited #{SecureRandom.hex(4)}",
          type: "merchandise",
          status: "active",
          inventory_mode: "unlimited"
        )
        group_id = SecureRandom.uuid
        result = Reserve.call(
          product:,
          event_date_ids: [ @event_date.id ],
          package_quantity: 1,
          admissions_per_unit: 1,
          reservation_group_id: group_id,
          expires_at: 1.minute.ago
        )
        assert result.success?, result.error&.message
        group_id
      end
    end
  end
end
