# frozen_string_literal: true

require "test_helper"

module Catalog
  module Public
    class EventAvailabilitySummaryTest < ActiveSupport::TestCase
      include PerformanceQueryHelpers

      setup do
        @event = events_events(:ready_listing)
        @event.update_columns(status: "published", visibility: "public")
        @at = Time.utc(2026, 9, 1, 12, 0, 0)
        @future_date = @event.event_dates.create!(
          starts_at: @at + 1.day, ends_at: @at + 1.day + 2.hours, status: "scheduled"
        )
      end

      test "returns separate event lifecycle and ticket availability fields" do
        create_ticket_product(capacity: 2)

        assert_equal(
          { event_lifecycle: "upcoming", ticket_availability: "available", price_from_minor: 1_000 },
          summary
        )
      end

      test "ongoing dates take precedence over future dates" do
        @event.event_dates.create!(
          starts_at: @at - 1.hour, ends_at: @at + 1.hour, status: "scheduled"
        )

        assert_equal "ongoing", summary.fetch(:event_lifecycle)
      end

      test "reports ended when a non-cancelled date has ended and none is upcoming" do
        replace_dates(
          [ { starts_at: @at - 3.hours, ends_at: @at - 1.hour, status: "completed" } ]
        )

        assert_equal "ended", summary.fetch(:event_lifecycle)
      end

      test "reports unscheduled when dates are absent or only postponed and cancelled" do
        replace_dates(
          [
            { starts_at: @at - 3.hours, ends_at: @at - 1.hour, status: "postponed" },
            { starts_at: @at + 1.day, ends_at: @at + 1.day + 1.hour, status: "cancelled" }
          ]
        )

        assert_equal "unscheduled", summary.fetch(:event_lifecycle)

        replace_dates([])
        assert_equal "unscheduled", summary.fetch(:event_lifecycle)
      end

      test "uses no_public_tickets for gated-only ticket inventory" do
        create_ticket_product(audience: "access_code", capacity: 2)

        assert_equal "no_public_tickets", summary.fetch(:ticket_availability)
        assert_nil summary.fetch(:price_from_minor)
      end

      test "public starting price ignores cheaper access-code tickets" do
        create_ticket_product(capacity: 2, amount_minor: 50_000)
        create_ticket_product(audience: "access_code", capacity: 2, amount_minor: 5_000)

        assert_equal 50_000, summary.fetch(:price_from_minor)
      end

      test "uses no_eligible_dates when public ticket products have no future scheduled date" do
        past_date = replace_dates(
          [ { starts_at: @at - 3.hours, ends_at: @at - 1.hour, status: "scheduled" } ]
        ).sole
        create_ticket_product(capacity: 2, dates: [ past_date ])

        assert_equal "no_eligible_dates", summary.fetch(:ticket_availability)
      end

      test "reports coming_soon for an eligible public offer before its sales window" do
        create_ticket_product(capacity: 2, sales_start_at: @at + 1.hour)

        assert_equal "coming_soon", summary.fetch(:ticket_availability)
      end

      test "reports sales_closed when all eligible public offers have ended sales" do
        create_ticket_product(capacity: 2, sales_end_at: @at)

        assert_equal "sales_closed", summary.fetch(:ticket_availability)
      end

      test "reports sold_out only when all eligible public offers are exhausted" do
        product = create_ticket_product(capacity: 1)
        product.inventories.find_by!(event_date_id: nil).update!(sold_count: 1)

        assert_equal "sold_out", summary.fetch(:ticket_availability)
      end

      test "an available public offer takes precedence over sold-out offers" do
        sold_out = create_ticket_product(capacity: 1)
        sold_out.inventories.find_by!(event_date_id: nil).update!(sold_count: 1)
        create_ticket_product(capacity: 2)

        assert_equal "available", summary.fetch(:ticket_availability)
      end

      test "reports unavailable when eligible public inventory configuration is missing" do
        product = create_ticket_product(capacity: 2)
        product.inventories.delete_all

        assert_equal "unavailable", summary.fetch(:ticket_availability)
      end

      test "reports unavailable when an active public offer has no current price" do
        product = create_ticket_product(capacity: 2)
        product.prices.delete_all

        assert_equal "unavailable", summary.fetch(:ticket_availability)
      end

      test "reports unavailable when an active ticket is missing its ticket type" do
        product = create_ticket_product(capacity: 2)
        product.ticket_type.destroy!

        assert_equal "unavailable", summary.fetch(:ticket_availability)
      end

      test "resolves more than fifty active public ticket products" do
        insert_ticket_products(count: 51, audience: "public")

        assert_equal "available", summary.fetch(:ticket_availability)
      end

      test "gated-only products never create public ticket availability" do
        insert_ticket_products(count: 51, audience: "access_code")

        assert_equal "no_public_tickets", summary.fetch(:ticket_availability)
      end

      test "resolves ticket availability with more than one hundred event dates" do
        create_ticket_product(capacity: 2)
        operation = lambda do
          100.times do |index|
            starts_at = @at + (index + 2).days
            @event.event_dates.create!(
              starts_at:, ends_at: starts_at + 1.hour, status: "scheduled"
            )
          end
        end
        defined?(Prosopite) ? Prosopite.pause(&operation) : operation.call

        assert_equal "available", summary.fetch(:ticket_availability)
      end

      test "availability is unchanged when an event follows one thousand page-neighbor offers" do
        events = 20.times.map do |index|
          Events::Event.create!(
            organization: @event.organization,
            created_by: core_users(:super_admin),
            title: "Discovery page neighbor #{index}",
            slug: "discovery-neighbor-#{index}-#{SecureRandom.hex(4)}",
            status: "published",
            visibility: "public",
            timezone: "Africa/Addis_Ababa",
            currency: "ETB"
          )
        end
        event_rows = [ *events, @event ]
        operation = -> { insert_public_products(events: event_rows, products_per_event: 50) }
        defined?(Prosopite) ? Prosopite.pause(&operation) : operation.call
        loaded_events = Events::Event.includes(:event_dates).where(id: event_rows.map(&:id)).index_by(&:id)
        page = [ *events.map { |event| loaded_events.fetch(event.id) }, loaded_events.fetch(@event.id) ]
        expected_product_count = Catalog::EventProduct.active.tickets.joins(:ticket_type)
          .where(event_id: event_rows.map(&:id), ticketing_ticket_types: { audience: "public" }).count
        batch_sizes = []
        trace = TracePoint.new(:call) do |call|
          if call.defined_class == ProductAvailability.singleton_class && call.method_id == :for
            batch_sizes << call.binding.local_variable_get(:products).size
          end
        end

        GC.start
        allocated_before = GC.stat(:total_allocated_objects)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = nil
        query_count = Prosopite.pause do
          count_database_queries do
            result = trace.enable { EventAvailabilitySummary.call(events: page, at: @at) }
          end
        end
        elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1_000
        allocated_objects = GC.stat(:total_allocated_objects) - allocated_before

        assert_equal "available", result.fetch(@event.id).fetch(:ticket_availability)
        assert_operator query_count, :<, 100
        assert_equal expected_product_count, batch_sizes.sum
        assert_operator batch_sizes.length, :>, 1
        assert_operator batch_sizes.max, :<=, EventAvailabilitySummary::PRODUCT_BATCH_SIZE
        if ENV["REPORT_PUBLIC_CATALOG_METRICS"] == "1"
          puts "G44 public catalog: products=#{expected_product_count}, batches=#{batch_sizes.length}, " \
               "max_batch=#{batch_sizes.max}, queries=#{query_count}, elapsed_ms=#{elapsed_ms.round(1)}, " \
               "allocated_objects=#{allocated_objects}"
        end
      end

      private

      def summary
        event = Events::Event.includes(:event_dates).find(@event.id)
        EventAvailabilitySummary.call(events: [ event ], at: @at).fetch(event.id)
      end

      def replace_dates(rows)
        operation = lambda do
          @event.event_dates.destroy_all
          rows.map { |attributes| @event.event_dates.create!(attributes) }
        end
        defined?(Prosopite) ? Prosopite.pause(&operation) : operation.call
      end

      def insert_ticket_products(count:, audience:)
        insert_public_products(events: [ @event ], products_per_event: count, audience:)
      end

      def insert_public_products(events:, products_per_event:, audience: "public")
        now = Time.current
        products = events.flat_map do |event|
          products_per_event.times.map do |index|
            {
            id: SecureRandom.uuid,
            event_id: event.id,
            name: "Fanout ticket #{SecureRandom.hex(4)} #{event.id}-#{index}",
            type: "ticket",
            status: "active",
            inventory_mode: "unlimited",
            schedule_change_refund_policy: "full_or_partial",
            created_at: now,
            updated_at: now
            }
          end
        end
        Catalog::EventProduct.insert_all!(products)
        Ticketing::TicketType.insert_all!(products.map do |product|
          {
            event_product_id: product.fetch(:id),
            audience:,
            date_selection: "fixed",
            created_at: now,
            updated_at: now
          }
        end)
        Catalog::ProductPrice.insert_all!(products.map do |product|
          {
            event_product_id: product.fetch(:id),
            currency: "ETB",
            amount_minor: 1_000,
            type: "base",
            active_from: @at - 1.hour,
            created_at: now,
            updated_at: now
          }
        end)
      end

      def create_ticket_product(audience: "public", capacity:, dates: [ @future_date ],
        sales_start_at: nil, sales_end_at: nil, amount_minor: 1_000)
        result = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: {
            name: "Availability #{SecureRandom.hex(4)}", type: "ticket",
            sales_start_at:, sales_end_at:
          },
          ticket_type_attributes: {
            audience:, approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
          },
          price_attributes: { currency: "ETB", amount_minor:, active_from: @at - 1.hour },
          inventory_configuration: { mode: "event_wide", capacity: }
        )
        assert_predicate result, :success?, result.error&.message

        dates.each do |date|
          result.value.product_accesses.create!(event_date: date, type: "venue", usage_limit: nil)
        end
        activation = Catalog::Products::Activate.call(product: result.value, actor: core_users(:super_admin))
        assert_predicate activation, :success?, activation.error&.message

        activation.value
      end
    end
  end
end
