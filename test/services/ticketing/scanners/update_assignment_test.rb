# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanners
    class UpdateAssignmentTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @new_starts_at = Time.current
        @new_ends_at = 4.days.from_now
        @operator = Core::User.create!(
          email: "scope-operator-#{SecureRandom.hex(5)}@example.com",
          phone: "2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}"
        )
        @staff_assignment = Events::EventStaffAssignment.create!(
          event: @event,
          organization: @event.organization,
          user: @operator,
          role: "scanner",
          status: "active"
        )
        @device = ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "scope-device-#{SecureRandom.hex(6)}"
        )
        @assignment = ScannerDeviceAssignment.create!(
          scanner_device: @device,
          event: @event,
          event_staff_assignment: @staff_assignment,
          assigned_by: @actor,
          starts_at: Time.current,
          ends_at: 3.days.from_now
        )
        @event_date = @event.event_dates.where(status: "scheduled").first
        @first_zone = create_zone("Main")
        @second_zone = create_zone("VIP")
      end

      test "defines the scanner assignment scope update command" do
        assert Scanners.const_defined?(:UpdateAssignment, false)
      end

      test "replaces selected zones and advances the event schedule cursor" do
        previous_version = @event.reload.schedule_version
        result = update_scope(zone_mode: "selected_zones", zone_ids: [ @first_zone.id ], key: "scope-one")

        assert result.success?, result.error&.message
        assert_equal [ @first_zone.id ], @assignment.assignment_zones.pluck(:access_zone_id)
        assert_equal previous_version + 1, @event.reload.schedule_version
        assert_equal [ @first_zone.id ], result.value.assignment.assignment_zones.pluck(:access_zone_id)
      end

      test "all current zones snapshots only active event zones" do
        inactive_zone = create_zone("Closed", active: false)
        result = update_scope(zone_mode: "all_current_zones", zone_ids: [], key: "scope-all")

        assert result.success?, result.error&.message
        assert_equal [ @first_zone.id, @second_zone.id ].sort,
          @assignment.assignment_zones.pluck(:access_zone_id).sort
        refute_includes @assignment.assignment_zones.pluck(:access_zone_id), inactive_zone.id
      end

      test "an empty selected-zone scope grants no zone access" do
        result = update_scope(zone_mode: "selected_zones", zone_ids: [], key: "scope-none")

        assert result.success?, result.error&.message
        assert_empty @assignment.assignment_zones
      end

      test "replays a scope change without another audit or schedule-version bump" do
        result = nil
        operation = -> { result = update_scope(zone_mode: "selected_zones", zone_ids: [ @first_zone.id ], key: "scope-replay") }

        assert_idempotent(operation, counter: -> { @event.reload.schedule_version })
        assert result.success?, result.error&.message
        assert result.value.replayed?
      end

      test "rejects a zone from another event and unauthorized actors" do
        other_zone = events_events(:draft_concert).access_zones.create!(
          type: "venue",
          name: "Other Gate #{SecureRandom.hex(3)}",
          code: "other-#{SecureRandom.hex(3)}"
        )
        invalid_zone = update_scope(zone_mode: "selected_zones", zone_ids: [ other_zone.id ], key: "scope-wrong-zone")
        forbidden = Ticketing::Scanners::UpdateAssignment.call(
          assignment: @assignment,
          actor: core_users(:attendee),
          zone_mode: "selected_zones",
          zone_ids: [ @first_zone.id ],
          idempotency_key: "scope-forbidden"
        )

        assert_equal "zone_invalid", invalid_zone.error.code
        assert_equal "assignment_forbidden", forbidden.error.code
      end

      private

      def update_scope(zone_mode:, zone_ids:, key:)
        Ticketing::Scanners::UpdateAssignment.call(
          assignment: @assignment,
          actor: @actor,
          zone_mode:,
          zone_ids:,
          starts_at: @new_starts_at,
          ends_at: @new_ends_at,
          idempotency_key: key
        )
      end

      def create_zone(name, active: true)
        @event.access_zones.create!(
          event_date: @event_date,
          type: "venue",
          name: "#{name} Gate #{SecureRandom.hex(3)}",
          code: "#{name.downcase}-#{SecureRandom.hex(3)}",
          active:
        )
      end
    end
  end
end
