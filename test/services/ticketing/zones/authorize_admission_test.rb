# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Zones
    class AuthorizeAdmissionTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        @product_access = @product.product_accesses.first
        @device = Ticketing::ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "scanner-#{SecureRandom.hex(4)}",
          token_digest: Core::KeyedDigest.digest(
            namespace: "ticketing-scanner-device",
            value: SecureRandom.hex(32)
          )
        )
        @assignment = Ticketing::ScannerDeviceAssignment.create!(
          scanner_device: @device,
          event: @event,
          assigned_by: @manager
        )
      end

      test "allows nil zone when the event has no active zones for the product access" do
        result = authorize

        assert result.success?
      end

      test "requires both product and assignment zone mappings when zones are enabled" do
        zone = create_zone

        missing_mappings = authorize
        refute missing_mappings.success?
        assert_equal "zone_required", missing_mappings.error.code

        Catalog::ProductAccessZone.create!(product_access: @product_access, access_zone: zone)
        Ticketing::ScannerAssignmentZone.create!(
          scanner_device_assignment: @assignment,
          access_zone: zone
        )

        granted = authorize(access_zone: zone)
        assert granted.success?
      end

      test "rejects a wrong date or wrong type zone" do
        current_zone = create_zone
        Catalog::ProductAccessZone.create!(product_access: @product_access, access_zone: current_zone)
        Ticketing::ScannerAssignmentZone.create!(
          scanner_device_assignment: @assignment,
          access_zone: current_zone
        )

        other_date = @event.event_dates.create!(
          starts_at: 4.days.from_now,
          ends_at: 4.days.from_now + 4.hours,
          status: "scheduled"
        )
        wrong_date_zone = create_zone(event_date: other_date, code: "wrong-date")
        wrong_type_zone = create_zone(type: "parking", code: "wrong-type")

        wrong_date = authorize(access_zone: wrong_date_zone)
        refute wrong_date.success?
        assert_equal "wrong_zone", wrong_date.error.code

        wrong_type = authorize(access_zone: wrong_type_zone)
        refute wrong_type.success?
        assert_equal "wrong_zone", wrong_type.error.code
      end

      test "rejects a supplied zone when zones are not configured" do
        inactive_zone = create_zone(active: false)

        result = authorize(access_zone: inactive_zone)

        refute result.success?
        assert_equal "wrong_zone", result.error.code
      end

      private

      def authorize(access_zone: nil)
        Ticketing::Zones::AuthorizeAdmission.call(
          assignment: @assignment,
          product_access: @product_access,
          access_zone:,
          now: Time.current
        )
      end

      def create_zone(event_date: @product_access.event_date, type: "venue", code: nil, active: true)
        @event.access_zones.create!(
          event_date:,
          type:,
          name: code || "Main gate",
          code: code || "zone-#{SecureRandom.hex(4)}",
          active:,
          sort_order: 1
        )
      end
    end
  end
end
