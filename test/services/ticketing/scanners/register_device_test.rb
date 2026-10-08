# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanners
    class RegisterDeviceTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @organization = organizations_organizations(:three)
        @identifier = "shared-installation-#{SecureRandom.hex(6)}"
      end

      test "reuses a device owned by an active event collaborator organization" do
        @event.event_organizations.create!(
          organization: @organization,
          type: "co_organizer",
          role: "operations",
          status: "active"
        )
        device = ScannerDevice.create!(
          organization: @organization,
          device_identifier: @identifier
        )

        result = RegisterDevice.call(
          event: @event,
          delegated_grant: grant,
          device_identifier: @identifier
        )

        assert result.success?, result.error&.message
        assert result.value.reused
        assert_equal device.id, result.value.device.id
      end

      test "does not reuse a device owned by an unrelated organization" do
        ScannerDevice.create!(
          organization: @organization,
          device_identifier: @identifier
        )

        result = RegisterDevice.call(
          event: @event,
          delegated_grant: grant,
          device_identifier: @identifier
        )

        assert_equal "device_scope_forbidden", result.error.code
      end

      private

      def grant
        Events::StaffAssignments::DelegatedGrant.new(
          event_id: @event.id,
          role: "scanner",
          grantor_id: @actor.id,
          source_type: "Ticketing::ScannerInvitation",
          source_id: SecureRandom.uuid,
          issued_at: Time.current
        )
      end
    end
  end
end
