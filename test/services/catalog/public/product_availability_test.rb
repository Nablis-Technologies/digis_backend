# frozen_string_literal: true

require "test_helper"

module Catalog
  module Public
    class ProductAvailabilityTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @at = Time.utc(2026, 9, 1, 12, 0, 0)
      end

      test "returns available for an unlimited product inside its sales window" do
        product = create_product(inventory_mode: "unlimited")

        assert_equal "available", availability_for(product)
      end

      test "returns coming soon for an unlimited product before its sale window" do
        product = create_product(inventory_mode: "unlimited", sales_start_at: @at + 1.hour)

        assert_equal "coming_soon", availability_for(product)
      end

      test "sale-window state takes precedence over missing or exhausted capacity" do
        upcoming = create_product(inventory_mode: "event_wide", sales_start_at: @at + 1.hour)
        closed = create_product(inventory_mode: "event_wide", sales_end_at: @at)
        closed.inventories.create!(capacity: 1, held_count: 0, sold_count: 1)

        assert_equal "coming_soon", availability_for(upcoming)
        assert_equal "sales_closed", availability_for(closed)
      end

      test "sales end is exclusive and reports closed at the exact cutoff" do
        product = create_product(inventory_mode: "unlimited", sales_end_at: @at)

        assert_equal "sales_closed", availability_for(product)
      end

      test "returns available when an inventory pool satisfies the minimum order" do
        product = create_product(inventory_mode: "event_wide")
        product.inventories.create!(capacity: 3, held_count: 1, sold_count: 1)

        assert_equal "available", availability_for(product)
      end

      test "returns sold out when every required inventory pool is exhausted" do
        date = @event.event_dates.create!(starts_at: @at + 1.hour, ends_at: @at + 3.hours, status: "scheduled")
        product = create_ticket_product(
          date_selection: "fixed", dates: [ date ], inventory_mode: "event_wide_and_per_date", capacities: [ 1 ]
        )
        product.inventories.find_by!(event_date_id: date.id).update!(sold_count: 1)

        assert_equal "sold_out", availability_for(product)
      end

      test "returns sold out when remaining capacity is below the minimum order" do
        product = create_product(inventory_mode: "event_wide", min_per_order: 2)
        product.inventories.create!(capacity: 1, held_count: 0, sold_count: 0)

        assert_equal "sold_out", availability_for(product)
      end

      test "returns no eligible dates when all accessed dates are past" do
        past_date = event_date(starts_at: @at - 3.hours, ends_at: @at - 1.hour)
        product = create_ticket_product(
          date_selection: "fixed", dates: [ past_date ], inventory_mode: "event_wide"
        )

        assert_equal "no_eligible_dates", availability_for(product)
      end

      test "fails closed when a configured inventory mode has no capacity row" do
        product = create_product(inventory_mode: "event_wide")

        assert_equal "unavailable", availability_for(product)
      end

      test "fixed offers require every access date to remain scheduled and future" do
        past_date = event_date(starts_at: @at - 3.hours, ends_at: @at - 1.hour)
        future_date = event_date(starts_at: @at + 1.day, ends_at: @at + 1.day + 2.hours)
        product = create_ticket_product(
          date_selection: "fixed", dates: [ past_date, future_date ], inventory_mode: "unlimited"
        )

        assert_equal "no_eligible_dates", availability_for(product)
      end

      test "choose-one offers remain available when one future access date has capacity" do
        past_date = event_date(starts_at: @at - 3.hours, ends_at: @at - 1.hour)
        future_date = event_date(starts_at: @at + 1.day, ends_at: @at + 1.day + 2.hours)
        product = create_ticket_product(
          date_selection: "choose_one", dates: [ past_date, future_date ], inventory_mode: "per_date"
        )

        assert_equal "available", availability_for(product)
      end

      test "choose-one stream offer ignores exhausted physical venue capacity" do
        date = event_date(
          starts_at: @at + 1.day, ends_at: @at + 1.day + 2.hours,
          venue_capacity: 1, issued_venue_count: 1
        )
        product = create_ticket_product(
          date_selection: "choose_one", dates: [ date ], inventory_mode: "unlimited", access_type: "stream"
        )

        assert_equal "available", availability_for(product)
      end

      test "fixed stream offer is unavailable when its access date passed despite another future date" do
        past_date = event_date(starts_at: @at - 1.day, ends_at: @at - 1.day + 2.hours)
        event_date(starts_at: @at + 2.days, ends_at: @at + 2.days + 2.hours)
        product = create_ticket_product(
          date_selection: "fixed", dates: [ past_date ], inventory_mode: "unlimited", access_type: "stream"
        )

        assert_equal "no_eligible_dates", availability_for(product)
      end

      test "choose-one availability handles many dates using pre-indexed capacity and date snapshots" do
        dates = 30.times.map do |index|
          start = @at + (index + 1).days
          event_date(starts_at: start, ends_at: start + 2.hours)
        end
        product = create_ticket_product(
          date_selection: "choose_one", dates:, inventory_mode: "per_date"
        )

        capacity_plans = 0
        trace = TracePoint.new(:call) do |event|
          capacity_plans += 1 if event.defined_class == Catalog::Inventory::Capacity.singleton_class &&
            event.method_id == :plan_from_snapshot!
        end
        state = trace.enable { availability_for(product) }

        assert_equal "available", state
        assert_equal 1, capacity_plans
      end

      test "a misconfigured eligible date takes precedence over a sold-out date" do
        first = event_date(starts_at: @at + 1.day, ends_at: @at + 1.day + 2.hours)
        second = event_date(starts_at: @at + 2.days, ends_at: @at + 2.days + 2.hours)
        product = create_ticket_product(
          date_selection: "choose_one", dates: [ first, second ], inventory_mode: "per_date", capacities: [ 1, 1 ]
        )
        product.inventories.find_by!(event_date_id: first.id).destroy!
        product.inventories.find_by!(event_date_id: second.id).update!(sold_count: 1)

        assert_equal "unavailable", availability_for(product)
      end

      test "per-date inventory requires capacity on an eligible choose-one date" do
        date = event_date(starts_at: @at + 1.day, ends_at: @at + 1.day + 2.hours)
        product = create_ticket_product(
          date_selection: "choose_one", dates: [ date ], inventory_mode: "per_date", capacities: [ 0 ]
        )

        assert_equal "sold_out", availability_for(product)
      end

      test "venue capacity can exhaust an otherwise unlimited ticket offer" do
        date = event_date(
          starts_at: @at + 1.day, ends_at: @at + 1.day + 2.hours,
          venue_capacity: 1, issued_venue_count: 1
        )
        product = create_ticket_product(
          date_selection: "fixed", dates: [ date ], inventory_mode: "unlimited"
        )

        assert_equal "sold_out", availability_for(product)
      end

      private

      def availability_for(product)
        event = Events::Event.includes(:event_dates).find(@event.id)
        product = Catalog::EventProduct.includes(:ticket_type, :inventories, :product_accesses).find(product.id)
        ProductAvailability.for(
          products: [ product ], events_by_id: { event.id.to_s => event }, at: @at
        ).fetch(product.id)
      end

      def event_date(starts_at:, ends_at:, venue_capacity: nil, issued_venue_count: 0)
        @event.event_dates.create!(
          starts_at:, ends_at:, status: "scheduled", venue_capacity:, issued_venue_count:
        )
      end

      def create_ticket_product(date_selection:, dates:, inventory_mode:, capacities: [], access_type: "venue")
        date_inventory = dates.each_with_index.map do |date, index|
          { event_date_id: date.id, capacity: capacities[index] || 10 }
        end
        inventory_configuration = { mode: inventory_mode }
        inventory_configuration[:capacity] = 10 if inventory_mode.in?(%w[event_wide event_wide_and_per_date])
        inventory_configuration[:dates] = date_inventory if inventory_mode.in?(%w[per_date event_wide_and_per_date])
        create_draft = lambda do
          Catalog::Products::CreateDraft.call(
            event: @event,
            actor: core_users(:super_admin),
            product_attributes: { name: "Ticket availability #{SecureRandom.hex(4)}", type: "ticket" },
            ticket_type_attributes: {
              audience: "public", approval_mode: "automatic", date_selection:, admissions_per_unit: 1
            },
            price_attributes: { currency: "ETB", amount_minor: 1_000, active_from: @at - 1.hour },
            inventory_configuration:, idempotency_key: SecureRandom.uuid
          )
        end
        result = defined?(Prosopite) ? Prosopite.pause(&create_draft) : create_draft.call
        assert_predicate result, :success?, result.error&.message

        dates.each do |date|
          attributes = { event_date: date, type: access_type, usage_limit: nil }
          attributes[:required_access_protection] = "public" if access_type == "stream"
          result.value.product_accesses.create!(attributes)
        end
        if date_selection == "fixed" && dates.length > 1
          allocation = 10_000 / dates.length
          dates.each do |date|
            result.value.product_date_allocations.create!(
              event_date: date, allocation_basis_points: allocation
            )
          end
        end
        activated = Catalog::Products::Activate.call(product: result.value, actor: core_users(:super_admin))
        assert_predicate activated, :success?, activated.error&.message

        activated.value
      end

      def create_product(inventory_mode:, sales_start_at: nil, sales_end_at: nil, min_per_order: 1)
        product = Catalog::EventProduct.create!(
          event: @event,
          name: "Availability #{SecureRandom.hex(4)}",
          type: "merchandise",
          status: "active",
          inventory_mode:,
          sales_start_at:,
          sales_end_at:,
          min_per_order:,
          schedule_change_refund_policy: "full_or_partial"
        )
        Catalog::ProductPrice.create!(
          event_product: product, type: "base", currency: "ETB", amount_minor: 1_000, active_from: @at - 1.hour
        )
        product
      end
    end
  end
end
