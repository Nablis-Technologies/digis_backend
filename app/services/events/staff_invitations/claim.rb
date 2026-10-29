# frozen_string_literal: true

module Events
  module StaffInvitations
    class Claim < Core::BaseService
      Result = Data.define(:record, :assignment, :replayed, :already_assigned) do
        def replayed? = replayed
        def already_assigned? = already_assigned
      end

      def initialize(token:, actor:, idempotency_key:, ip_address:, at: Time.current)
        @token = token.to_s.strip
        @actor = actor
        @idempotency_key_input = idempotency_key
        @ip_address = ip_address
        @at = at.to_time.utc
      end

      def call
        return failure(error(:invalid_idempotency_key, :bad_request)) unless idempotency_key
        return failure(invalid_claim) unless actor

        token_digest = StaffInvitation.claim_token_digest_for(token)
        request_digest = claim_request_digest(token_digest)
        audit_key = claim_audit_key
        replay = replay_result(audit_key:, request_digest:)
        return replay if replay

        throttle = Core::InvitationThrottle.call(actor_id: actor.id, token_digest:, ip_address:)
        return failure(throttle.error) if throttle.failure?
        return failure(invalid_claim) unless token.match?(/\A[0-9a-f]{64}\z/)

        invitation = StaffInvitation.find_by(claim_token_digest: token_digest)
        return failure(invalid_claim) unless invitation

        contact = invitation_contact(invitation)
        return failure(invalid_claim) unless contact

        contact_throttle = Core::InvitationThrottle.call(
          actor_id: nil,
          contact_digest: contact.rate_limit_digest,
          ip_address: nil
        )
        return failure(contact_throttle.error) if contact_throttle.failure?

        result = nil
        StaffInvitation.transaction do
          event = Events::Event.lock.find(invitation.event_id)
          invitation.lock!
          replay = replay_result(audit_key:, request_digest:)
          if replay
            result = replay
            next
          end

          validation = validate_claim(invitation, event, contact)
          if validation
            expire_if_due!(invitation)
            result = failure(validation)
            next
          end

          if other_active_general_role?(invitation)
            result = failure(error(:staff_assignment_role_change_required, :conflict))
            next
          end

          assignment = existing_assignment(invitation)
          if assignment && !assignment.active?
            result = failure(error(:staff_assignment_not_active, :conflict))
            next
          end

          already_assigned = assignment.present?
          assignment ||= create_assignment(invitation, event)
          accept_invitation!(invitation, assignment, audit_key:, request_digest:, already_assigned:)
          result = success(Result.new(record: invitation, assignment:, replayed: false, already_assigned:))
        end
        result
      rescue ActiveRecord::RecordNotFound
        failure(invalid_claim)
      rescue ActiveRecord::RecordNotUnique
        replay_result(audit_key:, request_digest:) || failure(error(:staff_assignment_already_exists, :conflict))
      rescue ActiveRecord::RecordInvalid => exception
        failure(Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.invitation_invalid"),
          code: "staff_invitation_invalid",
          status: :unprocessable_entity,
          errors: exception.record.errors.to_hash
        ))
      rescue Core::Audit::Record::ReplayConflict
        failure(error(:idempotency_conflict, :conflict))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :token, :actor, :idempotency_key_input, :ip_address, :at

      def idempotency_key
        @idempotency_key ||= Core::IdempotencyKey.new(idempotency_key_input)
      rescue ArgumentError
        nil
      end

      def claim_audit_key
        Core::KeyedDigest.digest(
          namespace: "events/staff-invitation-claim/#{actor.id}",
          value: idempotency_key.to_s
        )
      end

      def claim_request_digest(token_digest)
        Core::KeyedDigest.digest(
          namespace: "events/staff-invitation-claim-request/#{actor.id}",
          value: token_digest
        )
      end

      def replay_result(audit_key:, request_digest:)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit

        metadata = audit.metadata.deep_stringify_keys
        return failure(error(:idempotency_conflict, :conflict)) unless metadata["request_digest"] == request_digest

        invitation = StaffInvitation.find_by(id: metadata["invitation_id"])
        assignment = Events::EventStaffAssignment.find_by(id: metadata["assignment_id"])
        return failure(invalid_claim) unless invitation && assignment

        success(Result.new(
          record: invitation,
          assignment:,
          replayed: true,
          already_assigned: metadata["already_assigned"] == true || metadata["already_assigned"] == "true"
        ))
      end

      def invitation_contact(invitation)
        return unless invitation.contact_type == "phone"

        Core::InvitationContact.parse(phone: invitation.contact_ciphertext)
      rescue ArgumentError, ActiveRecord::Encryption::Errors::Decryption
        nil
      end

      def validate_claim(invitation, event, contact)
        return invalid_claim unless invitation.pending? && invitation.expires_at > at
        return error(:event_not_invitable, :conflict) if event.status.in?(%w[cancelled completed])
        return invalid_claim if event.organization.archived?
        return error(:invitation_phone_unverified, :forbidden) unless actor.verified_at.present?
        return error(:invitation_contact_mismatch, :forbidden) unless contact.normalized_value ==
          Core::InvitationContact.parse(phone: actor.phone).normalized_value

        nil
      rescue ArgumentError
        error(:invitation_contact_mismatch, :forbidden)
      end

      def existing_assignment(invitation)
        Events::EventStaffAssignment.lock.find_by(
          event_id: invitation.event_id,
          user_id: actor.id,
          role: invitation.role
        )
      end

      def other_active_general_role?(invitation)
        Events::EventStaffAssignment.where(
          event_id: invitation.event_id,
          user_id: actor.id,
          status: "active",
          role: Events::EventStaffAssignment::GENERAL_ROLES
        ).where.not(role: invitation.role).exists?
      end

      def create_assignment(invitation, event)
        assignment = Events::EventStaffAssignment.create!(
          event:,
          user: actor,
          organization: event.organization,
          role: invitation.role,
          status: "active",
          expires_at: invitation.assignment_expires_at
        )
        assignment.record_audit!(
          "event.staff.assigned",
          actor:,
          audited_changes: { user_id: actor.id, role: invitation.role },
          metadata: { invitation_id: invitation.id, event_id: event.id }
        )
        assignment
      end

      def accept_invitation!(invitation, assignment, audit_key:, request_digest:, already_assigned:)
        invitation.update!(
          status: "accepted",
          accepted_user: actor,
          accepted_at: at,
          claim_token_ciphertext: nil,
          claim_idempotency_key_digest: audit_key,
          claim_request_digest: request_digest
        )
        invitation.record_audit!(
          "events.staff_invitation.accepted",
          actor:,
          audit_key:,
          audited_changes: { status: [ "pending", "accepted" ] },
          metadata: {
            invitation_id: invitation.id,
            event_id: invitation.event_id,
            accepted_user_id: actor.id,
            assignment_id: assignment.id,
            role: invitation.role,
            request_digest:,
            already_assigned:
          }
        )
      end

      def expire_if_due!(invitation)
        return unless invitation.pending? && invitation.expires_at <= at

        result = Expire.call(event_id: invitation.event_id, contact_digest: invitation.contact_digest, at:, limit: 1)
        raise result.error if result.failure?
      end

      def invalid_claim
        error(:staff_invitation_claim_invalid, :unauthorized)
      end

      def error(key, status)
        Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.#{key}"),
          code: key.to_s,
          status:
        )
      end
    end
  end
end
