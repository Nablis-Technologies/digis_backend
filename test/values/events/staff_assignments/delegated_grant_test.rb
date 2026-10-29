# frozen_string_literal: true

require "test_helper"

module Events
  module StaffAssignments
    class DelegatedGrantTest < ActiveSupport::TestCase
      test "defines the typed delegated-grant value" do
        assert StaffAssignments.const_defined?(:DelegatedGrant, false)
      end

      test "validates the event role grantor source and issue time together" do
        event = events_events(:ready_listing)
        grant = DelegatedGrant.new(
          event_id: event.id,
          role: "scanner",
          grantor_id: core_users(:super_admin).id,
          source_type: "Ticketing::ScannerInvitation",
          source_id: SecureRandom.uuid,
          issued_at: Time.current
        )

        assert_predicate grant, :valid?
        assert grant.valid_for?(event:, role: "scanner")
        assert_not grant.valid_for?(event: events_events(:draft_concert), role: "scanner")
        assert_not grant.valid_for?(event:, role: "manager")
      end
    end
  end
end
