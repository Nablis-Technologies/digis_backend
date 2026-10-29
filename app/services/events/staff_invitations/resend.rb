# frozen_string_literal: true

require "securerandom"

module Events
  module StaffInvitations
    class Resend < Core::BaseService
      Result = Data.define(:record, :token, :replayed) do
        def replayed? = replayed
      end

      def initialize(invitation:, actor:, idempotency_key:, ip_address:, at: Time.current)
        @invitation = invitation
        @actor = actor
        @idempotency_key_input = idempotency_key
        @ip_address = ip_address
        @at = at.to_time.utc
      end

      def call
        key = idempotency_key
        return failure(error(:invalid_idempotency_key, :bad_request)) unless key
        return failure(error(:invitation_forbidden, :forbidden)) unless authorized?

        command_key = command_key_digest(key)
        request_digest = request_digest_for
        result = nil

        StaffInvitation.transaction do
          event = Events::Event.lock.find(invitation.event_id)
          locked_invitation = StaffInvitation.lock.find(invitation.id)
          @invitation = locked_invitation

          replay = replay_command(command_key:, request_digest:)
          if replay
            result = replay
            next
          end

          unless locked_invitation.pending? && locked_invitation.expires_at > at
            expire_if_due!
            result = failure(error(:invitation_not_resendable, :conflict))
            next
          end
          if event.status.in?(%w[cancelled completed])
            result = failure(error(:event_not_invitable, :conflict))
            next
          end
          unless Events::AuthorizationResolver.can_assign?(actor, event, locked_invitation.role)
            result = failure(error(:invitation_forbidden, :forbidden))
            next
          end

          contact = invitation_contact
          throttle = Core::InvitationThrottle.call(
            actor_id: actor.id,
            contact_digest: contact.rate_limit_digest,
            ip_address:
          )
          unless throttle.success?
            result = failure(throttle.error)
            next
          end

          previous_revision = locked_invitation.delivery_revision
          token = SecureRandom.hex(32)
          locked_invitation.update!(
            claim_token_ciphertext: token,
            claim_token_digest: StaffInvitation.claim_token_digest_for(token),
            delivery_revision: previous_revision + 1,
            delivery_status: "queued",
            delivery_attempts: 0,
            last_delivery_at: nil
          )
          publish_delivery!
          locked_invitation.record_audit!(
            "events.staff_invitation.resent",
            actor:,
            audit_key: command_key,
            audited_changes: { delivery_revision: [ previous_revision, locked_invitation.delivery_revision ] },
            metadata: {
              invitation_id: locked_invitation.id,
              event_id: event.id,
              request_digest:,
              delivery_revision: locked_invitation.delivery_revision
            }
          )
          result = success(Result.new(record: locked_invitation, token:, replayed: false))
        end
        result
      rescue ActiveRecord::RecordNotFound
        failure(error(:staff_invitation_not_found, :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(invitation_invalid(exception.record))
      rescue Core::Audit::Record::ReplayConflict
        failure(error(:idempotency_conflict, :conflict))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :invitation, :actor, :idempotency_key_input, :ip_address, :at

      def idempotency_key
        Core::IdempotencyKey.new(idempotency_key_input)
      rescue ArgumentError
        nil
      end

      def authorized?
        actor && Events::AuthorizationResolver.can_assign?(actor, invitation.event, invitation.role)
      end

      def invitation_contact
        attributes = if invitation.contact_type == "phone"
          { phone: invitation.contact_ciphertext }
        else
          { email: invitation.contact_ciphertext }
        end
        Core::InvitationContact.parse(**attributes)
      end

      def command_key_digest(key)
        Core::KeyedDigest.digest(
          namespace: "events/staff-invitation-resend/#{invitation.id}/#{actor.id}",
          value: key.to_s
        )
      end

      def request_digest_for
        Core::KeyedDigest.digest(
          namespace: "events/staff-invitation-resend-request",
          value: ActiveSupport::JSON.encode(invitation_id: invitation.id, actor_id: actor.id)
        )
      end

      def replay_command(command_key:, request_digest:)
        audit = Core::AuditLog.find_by(audit_key: command_key)
        return unless audit

        metadata = audit.metadata.deep_stringify_keys
        return failure(error(:idempotency_conflict, :conflict)) unless metadata["request_digest"] == request_digest

        token = if invitation.pending? && invitation.expires_at > at &&
            invitation.delivery_revision == metadata["delivery_revision"].to_i
          invitation.claim_token_ciphertext
        end
        success(Result.new(record: invitation, token:, replayed: true))
      end

      def expire_if_due!
        return unless invitation.pending? && invitation.expires_at <= at

        result = Expire.call(event_id: invitation.event_id, contact_digest: invitation.contact_digest, at:, limit: 1)
        raise result.error if result.failure?
      end

      def publish_delivery!
        key = Core::KeyedDigest.digest(
          namespace: "events/staff-invitation-delivery",
          value: "#{invitation.id}:#{invitation.delivery_revision}"
        )
        result = Core::Outbox::Publish.call(
          topic: "events",
          event_type: "events.staff_invitation.delivery_requested",
          aggregate: invitation,
          payload: { invitation_id: invitation.id, delivery_revision: invitation.delivery_revision },
          idempotency_key: key
        )
        raise result.error if result.failure?
      end

      def invitation_invalid(record)
        Core::BusinessError.new(
          I18n.t("events.staff_assignment.errors.invitation_invalid"),
          code: "staff_invitation_invalid",
          status: :unprocessable_entity,
          errors: record.errors.to_hash
        )
      end

      def error(key, status)
        Core::BusinessError.new(I18n.t("events.staff_assignment.errors.#{key}"), code: key.to_s, status:)
      end
    end
  end
end
