# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Scanners
    class CreateInvitationTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @starts_at = Time.current
        @ends_at = 3.days.from_now
        @expires_at = 2.days.from_now
      end

      test "defines the scanner invitation creation command" do
        assert Scanners.const_defined?(:CreateInvitation, false)
      end

      test "creates a phone-normalized pending grant and publishes only safe outbox data" do
        assignment_count = @event.event_staff_assignments.count
        result = create_invitation(phone: "0911 23 45 67", key: "create-invite-safe")

        assert result.success?, result.error&.message
        invitation = result.value.record
        assert_equal "pending", invitation.status
        assert_equal "+251911234567", invitation.phone
        assert_equal "Abel - Main Gate", invitation.display_label
        assert_equal "all_current_zones", invitation.zone_mode
        assert_empty invitation.selected_zone_ids
        assert_equal assignment_count, @event.event_staff_assignments.count
        assert_match(/\A[0-9]{6}\z/, result.value.pairing_code)
        assert_equal 64, result.value.token.length
        assert_response_secret_safe(invitation, result.value)

        event = Core::OutboxEvent.find_by!(
          event_type: "ticketing.scanner_invitation.delivery_requested",
          aggregate_id: invitation.id
        )
        assert_equal({
          "invitation_id" => invitation.id,
          "delivery_revision" => 1
        }, event.payload)
        audit = Core::AuditLog.find_by!(auditable: invitation, action: "ticketing.scanner_invitation.created")
        refute_includes audit.metadata.to_s, invitation.phone
        refute_includes audit.metadata.to_s, result.value.token
        refute_includes audit.metadata.to_s, result.value.pairing_code
      end

      test "accepts an event manager while keeping the permission grant event scoped" do
        manager = Core::User.create!(
          email: "scanner-manager-#{SecureRandom.hex(5)}@example.com",
          phone: "2519#{SecureRandom.random_number(100_000_000).to_s.rjust(8, "0")}"
        )
        Events::EventStaffAssignment.create!(
          event: @event,
          organization: @event.organization,
          user: manager,
          role: "manager",
          status: "active"
        )

        result = create_invitation(actor: manager, phone: "0911234568", key: "manager-invite")

        assert result.success?, result.error&.message
        assert_equal manager.id, result.value.record.created_by_id
        assert_empty manager.roles
      end

      test "rejects an invalid phone and an actor who cannot assign scanners" do
        invalid_phone = create_invitation(phone: "not a phone", key: "invalid-phone")
        unauthorized = create_invitation(
          actor: core_users(:attendee), phone: "0911234568", key: "unauthorized-invite"
        )

        assert_equal "phone_identity_invalid", invalid_phone.error.code
        assert_equal "invitation_forbidden", unauthorized.error.code
      end

      test "requires an idempotency key" do
        result = create_invitation(phone: "0911234568", key: nil)

        assert_equal "invalid_idempotency_key", result.error.code
      end

      test "replays the safe result without creating another invite or delivery" do
        results = []
        operation = lambda do
          results << create_invitation(phone: "0911234568", key: "invite-replay")
        end
        counter = lambda do
          ScannerInvitation.count + Core::OutboxEvent.where(
            event_type: "ticketing.scanner_invitation.delivery_requested"
          ).count
        end

        assert_idempotent(operation, counter:)
        result = results.last
        assert result.success?, result.error&.message
        assert result.value.replayed?
        assert_equal results.first.value.record.id, result.value.record.id
        assert_equal results.first.value.token, result.value.token
        assert_equal results.first.value.pairing_code, result.value.pairing_code
      end

      test "rejects an idempotency key reused for a changed recipient" do
        first = create_invitation(phone: "0911234568", key: "invite-conflict")
        second = create_invitation(phone: "0911234569", key: "invite-conflict")

        assert first.success?, first.error&.message
        assert_equal "idempotency_conflict", second.error.code
        assert_equal 1, ScannerInvitation.count
      end

      test "retries an active short-code digest collision" do
        existing = create_invitation(phone: "0911234568", key: "existing-code")
        assert existing.success?, existing.error&.message
        collision_code = existing.value.pairing_code.to_i
        replacement_code = (collision_code + 1) % 1_000_000
        SecureRandom.expects(:random_number).twice.returns(collision_code, replacement_code)

        result = Prosopite.pause do
          create_invitation(phone: "0911234569", key: "collision-retry")
        end

        assert result.success?, result.error&.message
        assert_equal replacement_code.to_s.rjust(6, "0"), result.value.pairing_code
        refute_equal existing.value.record.pairing_code_digest, result.value.record.pairing_code_digest
      end

      private

      def create_invitation(actor: @actor, phone:, key:, **overrides)
        Scanners::CreateInvitation.call(
          event: @event,
          actor:,
          phone:,
          label: overrides.fetch(:label, "Abel - Main Gate"),
          note: overrides.fetch(:note, "Main entrance"),
          zone_mode: overrides.fetch(:zone_mode, "all_current_zones"),
          zone_ids: overrides.fetch(:zone_ids, []),
          starts_at: overrides.fetch(:starts_at, @starts_at),
          ends_at: overrides.fetch(:ends_at, @ends_at),
          expires_at: overrides.fetch(:expires_at, @expires_at),
          idempotency_key: key
        )
      end

      def assert_response_secret_safe(invitation, result)
        assert_equal invitation.token, result.token
        assert invitation.pairing_code_digest.present?
        stored_code = ScannerInvitation.connection.select_value(
          "SELECT pairing_code_ciphertext FROM ticketing_scanner_invitations WHERE id = '#{invitation.id}'"
        )
        refute_includes stored_code, result.pairing_code
        assert_equal "+251911234567", invitation.phone
        assert_equal "Main entrance", invitation.note
      end
    end
  end
end
