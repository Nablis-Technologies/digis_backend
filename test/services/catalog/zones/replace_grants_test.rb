# frozen_string_literal: true

require "test_helper"

module Catalog
  module Zones
    class ReplaceGrantsTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @date = Events::EventDate.create!(
          event: @event,
          starts_at: 1.day.from_now,
          ends_at: 1.day.from_now + 4.hours
        )
        @product = Catalog::EventProduct.create!(
          event: @event,
          name: "Festival Pass",
          type: "merchandise",
          status: "draft",
          inventory_mode: "unlimited"
        )
        @product_access = @product.product_accesses.create!(event_date: @date, type: "venue")
        @zone = Events::AccessZone.create!(event: @event, name: "Main Floor", code: "MAIN", type: "venue")
      end

      test "increments the scanner schedule version when grants change" do
        initial_schedule_version = @event.reload.schedule_version

        result = ReplaceGrants.call(product_access: @product_access, zone_ids: [ @zone.id ])

        assert result.success?, result.error&.message
        assert_equal [ @zone.id ], result.value.product_access_zones.pluck(:access_zone_id)
        assert_equal initial_schedule_version + 1, @event.reload.schedule_version
      end
    end
  end
end
