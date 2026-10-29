# frozen_string_literal: true

require "test_helper"

module Catalog
  module Inventory
    class CapacityTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @event_date = @event.event_dates.create!(
          starts_at: 2.days.from_now, ends_at: 2.days.from_now + 2.hours,
          status: "scheduled", venue_capacity: 1
        )
        @product = Catalog::EventProduct.create!(
          event: @event, name: "Snapshot capacity", type: "merchandise", status: "active",
          inventory_mode: "event_wide_and_per_date",
          schedule_change_refund_policy: "full_or_partial"
        )
        @product.inventories.create!(capacity: 2, held_count: 0, sold_count: 0)
        @product.inventories.create!(
          event_date: @event_date, capacity: 2, held_count: 0, sold_count: 0
        )
        @line = Line.new(
          product: @product, event_date_ids: [ @event_date.id ],
          venue_event_date_ids: [ @event_date.id ], package_quantity: 1, admissions_per_unit: 1
        )
      end

      test "snapshot plan matches database planning and evaluates without checkout locks" do
        expected = Capacity.plan!(@line)
        inventory_rows = @product.inventories.to_a
        event_date_rows = @event.event_dates.to_a
        snapshot = Capacity::Snapshot.new(inventory_rows:, event_date_rows:)
        statements = []
        subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
          statements << payload[:sql]
        end

        begin
          plan = Capacity.plan_from_snapshot!(line: @line, snapshot:)
          violation = Capacity.evaluate(
            plan:, snapshot:
          )
        ensure
          ActiveSupport::Notifications.unsubscribe(subscriber)
        end

        assert_equal expected.inventory_ids, plan.inventory_ids
        assert_nil violation
        refute statements.any? { |sql| sql.match?(/FOR UPDATE|pg_advisory/i) }
      end

      test "evaluation revalidates a forged plan's demand line against its snapshot" do
        snapshot = Capacity::Snapshot.new(
          inventory_rows: @product.inventories.to_a,
          event_date_rows: @event.event_dates.to_a
        )
        invalid_line = Line.new(
          product: @product,
          event_date_ids: [ SecureRandom.uuid ],
          venue_event_date_ids: [],
          package_quantity: 1,
          admissions_per_unit: 1
        )
        forged_plan = Capacity::Plan.new(line: invalid_line, inventory_ids: [])

        error = assert_raises(Core::BusinessError) do
          Capacity.evaluate(plan: forged_plan, snapshot:)
        end

        assert_equal "event_date_unavailable", error.code
      end
    end
  end
end
