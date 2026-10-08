# frozen_string_literal: true

module Ticketing
  module OutboxHandlers
    # Closes Ticketing's scanner-side records after Events revokes the
    # authoritative event-staff assignment. Auth checks that Events row
    # directly, so outbox delay never leaves an online scanner authorized.
    class RevokeScannerAssignment < Core::BaseService
      def initialize(event:)
        @outbox_event = event
      end

      def call
        staff_assignment_id = outbox_event.payload.fetch("event_staff_assignment_id")
        counts = { device_assignments: 0, invitations: 0 }
        Ticketing::ApplicationRecord.transaction do
          assignments = scanner_assignments(staff_assignment_id).lock.to_a
          invitations = ScannerInvitation.where(
            event_staff_assignment_id: staff_assignment_id,
            status: "paired"
          ).order(:id).lock.to_a
          actor = Core::User.find_by(id: outbox_event.payload["actor_id"])
          assignments.each { |assignment| revoke_assignment!(assignment, actor:) }
          invitations.each { |invitation| revoke_invitation!(invitation, actor:) }
          counts = { device_assignments: assignments.length, invitations: invitations.length }
        end
        success(counts)
      rescue ActiveRecord::RecordInvalid => exception
        failure(Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.invalid_assignment"),
          code: "invalid_assignment",
          status: :unprocessable_entity,
          errors: exception.record.errors.to_hash
        ))
      end

      private

      attr_reader :outbox_event

      def scanner_assignments(staff_assignment_id)
        Ticketing::ScannerDeviceAssignment.where(event_staff_assignment_id: staff_assignment_id).order(:id)
      end

      def revoke_assignment!(assignment, actor:)
        now = Time.current
        Ticketing::ScannerSession.where(
          scanner_device_assignment_id: assignment.id,
          revoked_at: nil
        ).update_all(revoked_at: now, updated_at: now)

        return unless assignment.status.in?(%w[active suspended])

        previous_status = assignment.status
        assignment.update!(status: "revoked")
        record_revocation_audit!(assignment, actor:, previous_status:)
      end

      def revoke_invitation!(invitation, actor:)
        previous_status = invitation.status
        invitation.update!(
          status: "revoked",
          revoked_at: Time.current,
          paired_at: nil,
          token_ciphertext: nil,
          pairing_code_ciphertext: nil
        )
        invitation.record_audit!(
          "ticketing.scanner_invitation.staff_assignment_revoked",
          actor:,
          audit_key: "ticketing-staff-assignment-revoked-invitation-#{invitation.id}",
          audited_changes: { status: [ previous_status, "revoked" ] },
          metadata: {
            event_staff_assignment_id: invitation.event_staff_assignment_id,
            outbox_event_id: outbox_event.id
          }
        )
      end

      def record_revocation_audit!(assignment, actor:, previous_status:)
        assignment.record_audit!(
          "ticketing.scanner_device_assignment.revoked",
          actor:,
          audit_key: "ticketing-event-staff-revoked-#{assignment.id}",
          audited_changes: { status: [ previous_status, "revoked" ] },
          metadata: {
            event_staff_assignment_id: assignment.event_staff_assignment_id,
            outbox_event_id: outbox_event.id
          }
        )
      end
    end
  end
end
