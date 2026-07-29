# frozen_string_literal: true

require "test_helper"

module Catalog
  class InventoryReservationTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Test Product",
        type: "merchandise",
        min_per_order: 1,
        schedule_change_refund_policy: "full_or_partial"
      )
      @inventory = Catalog::ProductInventory.create!(
        event_product: @product,
        capacity: 100
      )
    end

    test "requires quantity to be positive" do
      res = Catalog::InventoryReservation.new(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        request_fingerprint: SecureRandom.hex(32),
        quantity: 0
      )
      assert res.invalid?
      assert_includes res.errors[:quantity], "must be greater than 0"
    end

    test "requires a valid status" do
      res = Catalog::InventoryReservation.new(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        request_fingerprint: SecureRandom.hex(32),
        quantity: 1,
        status: "bogus"
      )
      assert res.invalid?
      assert_includes res.errors[:status], "is not included in the list"
    end

    test "accepts all valid statuses" do
      %w[held processing committed released expired].each do |s|
        res = Catalog::InventoryReservation.new(
          product_inventory: @inventory,
          reservation_group_id: SecureRandom.uuid,
          request_fingerprint: SecureRandom.hex(32),
          quantity: 1,
          status: s,
          expires_at: s.in?(%w[held processing]) ? 1.hour.from_now : nil
        )
        assert res.valid?, "expected status #{s} to be valid"
      end
    end

    test "active scope returns held and processing reservations" do
      held = Catalog::InventoryReservation.create!(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        request_fingerprint: SecureRandom.hex(32),
        quantity: 1,
        status: "held",
        expires_at: 1.hour.from_now
      )
      processing = Catalog::InventoryReservation.create!(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        request_fingerprint: SecureRandom.hex(32),
        quantity: 1,
        status: "processing",
        expires_at: 1.hour.from_now
      )
      Catalog::InventoryReservation.create!(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        request_fingerprint: SecureRandom.hex(32),
        quantity: 1,
        status: "committed"
      )

      assert_includes Catalog::InventoryReservation.active, held
      assert_includes Catalog::InventoryReservation.active, processing
      assert_equal 2, Catalog::InventoryReservation.active.count
    end

    test "held? returns true only for held status" do
      res = Catalog::InventoryReservation.new(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        request_fingerprint: SecureRandom.hex(32),
        quantity: 1,
        status: "held",
        expires_at: 1.hour.from_now
      )
      assert res.held?
      assert_not res.committed?
      assert_not res.released?
      assert_not res.expired?
    end

    test "active? returns true for held and processing" do
      res = Catalog::InventoryReservation.new(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        request_fingerprint: SecureRandom.hex(32),
        quantity: 1,
        status: "committed"
      )
      assert_not res.active?
    end

    test "terminal? returns true for committed, released, expired" do
      %w[committed released expired].each do |s|
        res = Catalog::InventoryReservation.new(
          product_inventory: @inventory,
          reservation_group_id: SecureRandom.uuid,
          request_fingerprint: SecureRandom.hex(32),
          quantity: 1,
          status: s
        )
        assert res.terminal?, "expected terminal for #{s}"
      end
    end

    test "expired scope finds held reservations past expires_at" do
      fresh = Catalog::InventoryReservation.create!(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        request_fingerprint: SecureRandom.hex(32),
        quantity: 1,
        status: "held",
        expires_at: 1.hour.from_now
      )
      stale = Catalog::InventoryReservation.create!(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        request_fingerprint: SecureRandom.hex(32),
        quantity: 1,
        status: "held",
        expires_at: 1.minute.ago
      )

      travel_to Time.current do
        expired = Catalog::InventoryReservation.expired
        assert_includes expired, stale
        assert_not_includes expired, fresh
      end
    end
    test "requires admissions_per_unit to be >= 1" do
      res = Catalog::InventoryReservation.new(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        request_fingerprint: SecureRandom.hex(32),
        quantity: 1,
        admissions_per_unit: 0
      )
      assert res.invalid?
      assert_includes res.errors[:admissions_per_unit], "must be greater than or equal to 1"
    end

    test "defaults admissions_per_unit to 1" do
      res = Catalog::InventoryReservation.create!(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        request_fingerprint: SecureRandom.hex(32),
        quantity: 1,
        expires_at: 1.hour.from_now
      )
      assert_equal 1, res.admissions_per_unit
    end

    test "prevents both registration_id and order_item_id from being set" do
      res = Catalog::InventoryReservation.new(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        request_fingerprint: SecureRandom.hex(32),
        quantity: 1,
        registration_id: SecureRandom.uuid,
        order_item_id: SecureRandom.uuid
      )
      assert res.invalid?
    end

    test "requires a request fingerprint" do
      res = Catalog::InventoryReservation.new(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        quantity: 1,
        expires_at: 1.hour.from_now
      )

      assert res.invalid?
      assert_includes res.errors[:request_fingerprint], "can't be blank"
    end

    test "requires a 64 character request fingerprint" do
      res = Catalog::InventoryReservation.new(
        product_inventory: @inventory,
        reservation_group_id: SecureRandom.uuid,
        quantity: 1,
        expires_at: 1.hour.from_now,
        request_fingerprint: "a" * 63
      )

      assert res.invalid?
      assert_includes res.errors[:request_fingerprint], "is invalid"
    end
  end
end
