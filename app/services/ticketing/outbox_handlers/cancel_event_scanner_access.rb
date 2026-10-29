# frozen_string_literal: true

module Ticketing
  module OutboxHandlers
    # Removes scanner access after the Events domain has committed event
    # cancellation. Scanner auth also checks the event status directly, so this
    # handler is durable cleanup rather than the immediate authorization gate.
    class CancelEventScannerAccess < Core::BaseService
      def initialize(event:)
        @outbox_event = event
      end

      def call
        event_id = outbox_event.payload.fetch("event_id")
        actor = Events::EventCancellation.includes(:initiated_by).find_by(event_id:)&.initiated_by
        counts = { device_assignments: 0, invitations: 0 }
        Ticketing::ApplicationRecord.transaction do
          assignments = ScannerDeviceAssignment.where(event_id:).order(:id).lock.to_a
          invitations = ScannerInvitation.live.where(event_id:).order(:id).lock.to_a
          assignments.each do |assignment|
            counts[:device_assignments] += 1
            revoke_assignment!(assignment, event_id:, actor:)
          end
          invitations.each do |invitation|
            counts[:invitations] += 1
            revoke_invitation!(invitation, event_id:, actor:)
          end
        end

        success(counts)
      rescue ActiveRecord::RecordInvalid => exception
        failure(Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.scanner_invitation_invalid"),
          code: "scanner_invitation_invalid",
          status: :unprocessable_entity,
          errors: exception.record.errors.to_hash
        ))
      end

      private

      attr_reader :outbox_event

      def revoke_assignment!(assignment, event_id:, actor:)
        revoke_sessions(assignment.id)
        return unless assignment.status.in?(%w[active suspended])

        previous_status = assignment.status
        assignment.update!(status: "revoked")
        assignment.record_audit!(
          "ticketing.scanner_device_assignment.revoked",
          actor:,
          audit_key: "ticketing-event-cancelled-assignment-#{assignment.id}",
          audited_changes: { status: [ previous_status, "revoked" ] },
          metadata: { event_id:, outbox_event_id: outbox_event.id }
        )
      end

      def revoke_invitation!(invitation, event_id:, actor:)
        previous_status = invitation.status
        now = Time.current
        revoke_sessions_for_invitation(invitation.id, now)
        invitation.update!(
          status: "revoked",
          revoked_at: now,
          paired_at: nil,
          token_ciphertext: nil,
          pairing_code_ciphertext: nil
        )
        invitation.record_audit!(
          "ticketing.scanner_invitation.event_cancelled",
          actor:,
          audit_key: "ticketing-event-cancelled-invitation-#{invitation.id}",
          audited_changes: { status: [ previous_status, "revoked" ] },
          metadata: { event_id:, outbox_event_id: outbox_event.id }
        )
      end

      def revoke_sessions(assignment_id)
        now = Time.current
        Ticketing::ScannerSession.where(
          scanner_device_assignment_id: assignment_id,
          revoked_at: nil
        ).update_all(revoked_at: now, updated_at: now)
      end

      def revoke_sessions_for_invitation(invitation_id, now)
        Ticketing::ScannerSession.where(
          scanner_invitation_id: invitation_id,
          revoked_at: nil
        ).update_all(revoked_at: now, updated_at: now)
      end
    end
  end
end
