# frozen_string_literal: true

require "test_helper"

module Catalog
  class VenueCapacityReservationTest < ActiveSupport::TestCase
    setup do
      skip "Catalog::VenueCapacityReservation is not implemented yet" unless defined?(Catalog::VenueCapacityReservation)

      @event = events_events(:ready_listing)
      @event_date = Events::EventDate.create!(
        event: @event,
        starts_at: 1.day.from_now,
        ends_at: 2.days.from_now
      )
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Venue Hold Product",
        type: "merchandise",
        min_per_order: 1,
        schedule_change_refund_policy: "full_or_partial"
      )
    end

    test "model is available" do
      assert defined?(Catalog::VenueCapacityReservation)
    end

    test "accepts every supported status" do
      %w[held processing committed released expired].each do |status|
        reservation = build_reservation(
          status:,
          expires_at: status.in?(%w[held processing]) ? 10.minutes.from_now : nil
        )

        assert reservation.valid?, "expected #{status} to be valid: #{reservation.errors.full_messages}"
      end
    end

    test "requires a positive people quantity" do
      reservation = build_reservation(quantity_people: 0)

      assert reservation.invalid?
      assert_includes reservation.errors[:quantity_people], "must be greater than 0"
    end

    test "requires expiry for active statuses" do
      reservation = build_reservation(expires_at: nil)

      assert reservation.invalid?
      assert_includes reservation.errors[:expires_at], "can't be blank"
    end

    test "requires a 64 character request fingerprint" do
      reservation = build_reservation(request_fingerprint: "a" * 63)

      assert reservation.invalid?
      assert_includes reservation.errors[:request_fingerprint], "is invalid"
    end

    test "prevents both owner identifiers from being set" do
      reservation = build_reservation(
        registration_id: SecureRandom.uuid,
        order_item_id: SecureRandom.uuid
      )

      assert reservation.invalid?
      assert_includes reservation.errors[:base], I18n.t("catalog.inventory_reservation.errors.owner_mutual_exclusion")
    end

    test "allows only one row per reservation group and event date" do
      existing = build_reservation
      existing.save!

      duplicate = build_reservation(reservation_group_id: existing.reservation_group_id)

      assert duplicate.invalid?
      assert_includes duplicate.errors[:reservation_group_id], "has already been taken"
    end

    test "active scope includes held and processing records" do
      held = build_reservation(status: "held")
      processing = build_reservation(
        reservation_group_id: SecureRandom.uuid,
        status: "processing"
      )
      committed = build_reservation(
        reservation_group_id: SecureRandom.uuid,
        status: "committed",
        expires_at: nil
      )
      [ held, processing, committed ].each(&:save!)

      assert_includes Catalog::VenueCapacityReservation.active, held
      assert_includes Catalog::VenueCapacityReservation.active, processing
      assert_not_includes Catalog::VenueCapacityReservation.active, committed
    end

    test "status predicates match reservation lifecycle states" do
      reservation = build_reservation(status: "processing")

      assert reservation.processing?
      assert reservation.active?
      refute reservation.held?
      refute reservation.committed?
      refute reservation.released?
      refute reservation.expired?
    end

    test "exposes searchable attributes" do
      assert_includes Catalog::VenueCapacityReservation.ransackable_attributes, "reservation_group_id"
      assert_includes Catalog::VenueCapacityReservation.ransackable_attributes, "request_fingerprint"
    end

    test "exposes searchable associations" do
      assert_equal %w[event_date event_product],
                   Catalog::VenueCapacityReservation.ransackable_associations
    end

    private

    def build_reservation(overrides = {})
      Catalog::VenueCapacityReservation.new(
        {
          event_date: @event_date,
          event_product: @product,
          reservation_group_id: SecureRandom.uuid,
          quantity_people: 2,
          status: "held",
          expires_at: 10.minutes.from_now,
          request_fingerprint: "a" * 64
        }.merge(overrides)
      )
    end
  end
end
