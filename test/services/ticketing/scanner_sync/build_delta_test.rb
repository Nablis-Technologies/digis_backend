# frozen_string_literal: true

require "test_helper"

module Ticketing
  module ScannerSync
    class BuildDeltaTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        @assignment = build_scanner_assignment(
          event: @event,
          assigned_by: @manager,
          device_identifier: "delta-scanner-#{SecureRandom.hex(4)}"
        )
        @device = @assignment.scanner_device
      end

      test "publishes versioned revocation, attendee, schedule, and reversal feeds" do
        credential = @ticket.current_credential_generation.credentials.sole
        entry = Ticketing::AttendeeIndexEntry.find_by!(credential:)

        @event.update!(
          revocation_version: 2,
          attendee_index_version: 4,
          schedule_version: 3,
          admission_use_reversal_version: 1
        )
        Ticketing::Revocation.create!(
          event: @event,
          ticket: @ticket,
          revoked_through_version: 1,
          revocation_version: 2
        )
        Ticketing::CredentialRevocation.create!(
          event: @event,
          credential:,
          reason: "generation_replaced",
          revoked_at: Time.current,
          revocation_version: 2
        )
        entry.update!(removed: true, index_version: 3)
        _replacement_ticket, replacement_credential, _replacement_product = create_replacement_credential
        entry = Ticketing::AttendeeIndexEntry.find_by!(credential: replacement_credential)
        entry.update!(index_version: 4, removed: false)
        assert_equal 5, @event.reload.attendee_index_version

        result = Ticketing::ScannerSync::BuildDelta.call(
          assignment: @assignment,
          cursors: { revocations: 0, attendee_index: 0, schedule: 0, reversals: 0 }
        )

        assert_predicate result, :success?
        payload = result.value
        assert_equal 1, payload.fetch(:contract_version)
        assert_equal({
          revocations: 2,
          attendee_index: 5,
          schedule: 4,
          reversals: 1
        }, payload.fetch(:versions))
        assert payload.fetch(:signing_keys).key?("v1")
        assert_equal @ticket.id.to_s, payload.fetch(:package_revocations).fetch(:changed).sole.fetch(:tid)
        assert_equal credential.id.to_s,
                     payload.fetch(:credential_revocations).fetch(:changed).sole.fetch(:cid)
        changed = payload.fetch(:attendee_index).fetch(:changed)
        assert_equal true, changed.first.fetch(:removed)
        assert_equal false, changed.last.fetch(:removed)
        assert_equal %i[attendee_index schedule server_use_ids admission_use_reversals], payload.keys.last(4)
      end

      test "rejects a cursor that is ahead of the event version" do
        result = Ticketing::ScannerSync::BuildDelta.call(
          assignment: @assignment,
          cursors: { revocations: 1, attendee_index: 0, schedule: 0, reversals: 0 }
        )

        assert_predicate result, :failure?
        assert_equal "scanner_cursor_ahead", result.error.code
      end

      test "does not acknowledge the assignment while downloading a delta" do
        result = Ticketing::ScannerSync::BuildDelta.call(
          assignment: @assignment,
          cursors: { revocations: 0, attendee_index: 0, schedule: 0, reversals: 0 }
        )

        assert_predicate result, :success?
        assert_nil @assignment.reload.last_synced_at
        assert_equal 0, @assignment.last_revocation_version
        assert_equal 0, @assignment.last_attendee_index_version
      end

      private

      def create_replacement_credential
        replacement_product = create_package_product(admissions_per_unit: 2, delegation_enabled: true, transferable: true)
        @registration = create_confirmed_registration
        replacement_ticket = create_issued_ticket
        [
          replacement_ticket,
          replacement_ticket.current_credential_generation.credentials.sole,
          replacement_product
        ]
      end
    end
  end
end
