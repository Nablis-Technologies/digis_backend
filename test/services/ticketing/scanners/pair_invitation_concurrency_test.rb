# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanners
    class PairInvitationConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      setup do
        @event = events_events(:ready_listing)
        @creator = core_users(:super_admin)
        @phone = "2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}"
        @installation_id = "race-install-#{SecureRandom.hex(8)}"
        @idempotency_key = "pair-race-#{SecureRandom.hex(8)}"
        created = CreateInvitation.call(
          event: @event,
          actor: @creator,
          phone: @phone,
          starts_at: 1.minute.ago,
          ends_at: 3.days.from_now,
          expires_at: 2.days.from_now,
          idempotency_key: "pair-race-invite-#{SecureRandom.hex(8)}"
        )
        raise created.error unless created.success?

        @invitation = created.value.record
        @token = created.value.token
      end

      teardown do
        cleanup_pairing_records
      end

      test "concurrent exact pairing retries create one assignment and replay the same safe state" do
        race = run_database_race do
          PairInvitation.call(
            pairing_token: @token,
            pairing_method: "sms_link",
            installation_id: @installation_id,
            device_name: "Concurrent scanner",
            ip_address: "203.0.113.55",
            idempotency_key: @idempotency_key
          )
        end

        assert_empty race.errors, race.errors.inspect
        assert race.results.all?(&:success?), race.results.map { |result| result.error&.message }.inspect
        assert_equal 1, race.results.count { |result| !result.value.replayed? }
        assert_equal 1, race.results.count { |result| result.value.replayed? }
        assert_equal 1, ScannerSession.where(scanner_invitation: @invitation).count
        assert_equal 1, ScannerDeviceAssignment.where(event: @event, event_staff_assignment_id:
          @invitation.reload.event_staff_assignment_id).count
      end

      test "concurrent different pairing keys have exactly one claimant" do
        race = run_database_race do |index|
          PairInvitation.call(
            pairing_token: @token,
            pairing_method: "organizer_qr",
            installation_id: "distinct-install-#{index}-#{@installation_id}",
            device_name: "Gate phone #{index}",
            ip_address: "203.0.113.56",
            idempotency_key: "#{@idempotency_key}-different-#{index}"
          )
        end

        assert_empty race.errors, race.errors.inspect
        assert_equal 1, race.results.count(&:success?)
        assert_equal 1, race.results.count(&:failure?)
        assert_equal "pairing_invalid", race.results.find(&:failure?).error.code
        assert_equal 1, ScannerSession.where(scanner_invitation: @invitation).count
        assert_equal 1, ScannerDeviceAssignment.where(event: @event, event_staff_assignment_id:
          @invitation.reload.event_staff_assignment_id).count
      end

      private

      def cleanup_pairing_records
        return unless @invitation&.persisted?

        invitation = ScannerInvitation.find_by(id: @invitation.id)
        return unless invitation

        session_ids = ScannerSession.where(scanner_invitation_id: invitation.id).pluck(:id)
        assignment_id = invitation.scanner_device_assignment_id
        device_id = invitation.scanner_device_id
        staff_assignment_id = invitation.event_staff_assignment_id
        operator_id = invitation.paired_user_id

        Core::AuditLog.where(auditable_type: "Ticketing::ScannerSession", auditable_id: session_ids).delete_all
        ScannerSession.where(id: session_ids).delete_all
        invitation.update_columns(
          status: "revoked",
          paired_at: nil,
          paired_user_id: nil,
          event_staff_assignment_id: nil,
          scanner_device_id: nil,
          scanner_device_assignment_id: nil
        )
        ScannerAssignmentZone.where(scanner_device_assignment_id: assignment_id).delete_all if assignment_id
        Core::AuditLog.where(
          auditable_type: "Ticketing::ScannerDeviceAssignment", auditable_id: assignment_id
        ).delete_all if assignment_id
        ScannerDeviceAssignment.where(id: assignment_id).delete_all if assignment_id
        Core::AuditLog.where(auditable_type: "Ticketing::ScannerDevice", auditable_id: device_id).delete_all if device_id
        ScannerDevice.where(id: device_id).delete_all if device_id
        Core::AuditLog.where(
          auditable_type: "Events::EventStaffAssignment", auditable_id: staff_assignment_id
        ).delete_all if staff_assignment_id
        Events::EventStaffAssignment.where(id: staff_assignment_id).delete_all if staff_assignment_id
        Core::AuditLog.where(
          auditable_type: "Ticketing::ScannerInvitation", auditable_id: invitation.id
        ).delete_all
        Core::OutboxEvent.where(aggregate_id: invitation.id).delete_all
        ScannerInvitation.where(id: invitation.id).delete_all
        Core::AuditLog.where(actor_id: operator_id).delete_all if operator_id
        Core::User.where(id: operator_id).delete_all if operator_id
      end
    end
  end
end
