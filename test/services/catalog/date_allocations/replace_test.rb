# frozen_string_literal: true

require "test_helper"

module Catalog
  module DateAllocations
    class ReplaceTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @date_one = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                              ends_at: 1.day.from_now + 4.hours)
        @date_two = Events::EventDate.create!(event: @event, starts_at: 2.days.from_now,
                                              ends_at: 2.days.from_now + 4.hours)
        @date_three = Events::EventDate.create!(event: @event, starts_at: 3.days.from_now,
                                                ends_at: 3.days.from_now + 4.hours)
        @product = Catalog::EventProduct.create!(event: @event, name: "Festival Pass",
                                                  type: "merchandise", status: "draft",
                                                  inventory_mode: "unlimited")
        [ @date_one, @date_two, @date_three ].each do |date|
          @product.product_accesses.create!(event_date: date, type: "venue")
        end
      end

      test "replaces date allocations summing to 10000 bps" do
        result = Replace.call(
          product: @product,
          allocations: [
            { event_date_id: @date_one.id, allocation_basis_points: 4_000 },
            { event_date_id: @date_two.id, allocation_basis_points: 3_500 },
            { event_date_id: @date_three.id, allocation_basis_points: 2_500 }
          ]
        )

        assert result.success?, result.error&.message
        assert_equal 3, result.value.product_date_allocations.count
      end

      test "rejects allocations not summing to 10000" do
        result = Replace.call(
          product: @product,
          allocations: [
            { event_date_id: @date_one.id, allocation_basis_points: 4_000 },
            { event_date_id: @date_two.id, allocation_basis_points: 3_000 }
          ]
        )

        assert result.failure?
        assert_match(/sum to/i, result.error.message)
      end

      test "rejects active product" do
        @product = Catalog::EventProduct.create!(event: @event, name: "Active Pass",
                                                  type: "merchandise", status: "active",
                                                  inventory_mode: "unlimited")

        result = Replace.call(
          product: @product,
          allocations: [ { event_date_id: @date_one.id, allocation_basis_points: 10_000 } ]
        )

        assert result.failure?
        assert_match(/draft/i, result.error.message)
      end

      test "rejects allocations with zero or negative bps" do
        result = Replace.call(
          product: @product,
          allocations: [
            { event_date_id: @date_one.id, allocation_basis_points: 0 },
            { event_date_id: @date_two.id, allocation_basis_points: 10_000 }
          ]
        )

        assert result.failure?
      end

      test "atomically replaces existing allocations" do
        Replace.call(
          product: @product,
          allocations: [ { event_date_id: @date_one.id, allocation_basis_points: 10_000 } ]
        )

        result = Replace.call(
          product: @product,
          allocations: [
            { event_date_id: @date_one.id, allocation_basis_points: 5_000 },
            { event_date_id: @date_two.id, allocation_basis_points: 5_000 }
          ]
        )

        assert result.success?, result.error&.message
        assert_equal 2, result.value.product_date_allocations.count
        assert_equal 5_000, result.value.product_date_allocations.first.allocation_basis_points
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
          allocations: [ { event_date_id: @date_one.id, allocation_basis_points: 10_000 } ]
        )

        assert result.failure?
        assert_match(/immutable/i, result.error.message)
      end

      test "auto-generates an equal split across granted dates when allocations are empty" do
        result = Replace.call(product: @product, allocations: [])

        assert result.success?, result.error&.message
        rows = result.value.product_date_allocations
        assert_equal 3, rows.count
        assert_equal 10_000, rows.sum(&:allocation_basis_points)
        assert_equal [ 3_333, 3_333, 3_334 ], rows.map(&:allocation_basis_points).sort
      end

      test "auto-generates a 2500/2500/2500/2500 split for four granted dates" do
        @date_four = Events::EventDate.create!(event: @event, starts_at: 4.days.from_now,
                                                ends_at: 4.days.from_now + 4.hours)
        @product.product_accesses.create!(event_date: @date_four, type: "venue")

        result = Replace.call(product: @product, allocations: [])

        assert result.success?, result.error&.message
        rows = result.value.product_date_allocations
        assert_equal 4, rows.count
        assert_equal [ 2_500 ] * 4, rows.map(&:allocation_basis_points).sort
      end

      test "leaves allocations empty for a single-date product" do
        single = Catalog::EventProduct.create!(event: @event, name: "One Day Pass",
                                                type: "merchandise", status: "draft",
                                                inventory_mode: "unlimited")
        single.product_accesses.create!(event_date: @date_one, type: "venue")

        result = Replace.call(product: single, allocations: [])

        assert result.success?, result.error&.message
        assert_empty result.value.product_date_allocations.reload
      end

      test "leaves allocations empty for a choose_one ticket product" do
        created = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "Pick A Day", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "choose_one",
            admissions_per_unit: 1
          },
          inventory_configuration: { mode: "unlimited" }
        )
        assert created.success?, created.error&.message
        ticket = created.value
        [ @date_one, @date_two, @date_three ].each do |date|
          ticket.product_accesses.create!(event_date: date, type: "venue")
        end

        result = Replace.call(product: ticket, allocations: [])

        assert result.success?, result.error&.message
        assert_empty result.value.product_date_allocations.reload
      end

      test "leaves allocations empty for a full_only multi-date product" do
        full_only = Catalog::EventProduct.create!(
          event: @event, name: "Full Refund Pass", type: "merchandise", status: "draft",
          inventory_mode: "unlimited", schedule_change_refund_policy: "full_only"
        )
        [ @date_one, @date_two, @date_three ].each do |date|
          full_only.product_accesses.create!(event_date: date, type: "venue")
        end

        result = Replace.call(product: full_only, allocations: [])

        assert result.success?, result.error&.message
        assert_empty result.value.product_date_allocations.reload
      end

      test "rejects allocations for dates the product has no access on" do
        other_event = events_events(:draft_concert)
        no_access_date = Events::EventDate.create!(
          event: other_event,
          starts_at: 1.day.from_now,
          ends_at: 1.day.from_now + 4.hours
        )
        other_product = Catalog::EventProduct.create!(
          event: other_event, name: "Other Pass", type: "merchandise",
          status: "draft", inventory_mode: "unlimited"
        )

        result = Replace.call(
          product: other_product,
          allocations: [ { event_date_id: no_access_date.id, allocation_basis_points: 10_000 } ]
        )

        assert result.failure?
        assert_match(/no access grant/i, result.error.message)
      end
    end
  end
end
