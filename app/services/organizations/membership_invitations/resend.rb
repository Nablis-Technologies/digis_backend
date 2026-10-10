# frozen_string_literal: true

require "securerandom"

module Organizations
  module MembershipInvitations
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
        outcome = nil

        MembershipInvitation.transaction do
          invitation.lock!
          replay = replay_command(command_key:, request_digest:)
          if replay
            outcome = replay
            next
          end

          unless invitation.pending? && invitation.expires_at > at
            expire_if_due!
            outcome = failure(error(:invitation_not_resendable, :conflict))
            next
          end

          contact = invitation_contact
          throttle = Core::InvitationThrottle.call(
            actor_id: actor.id,
            contact_digest: contact.rate_limit_digest,
            ip_address:
          )
          unless throttle.success?
            outcome = failure(throttle.error)
            next
          end

          previous_revision = invitation.delivery_revision
          token = SecureRandom.hex(32)
          invitation.update!(
            claim_token_ciphertext: token,
            claim_token_digest: MembershipInvitation.claim_token_digest_for(token),
            delivery_revision: previous_revision + 1,
            delivery_status: "queued",
            delivery_attempts: 0,
            last_delivery_at: nil
          )
          publish_delivery!
          invitation.record_audit!(
            "organizations.membership_invitation.resent",
            actor:,
            audit_key: command_key,
            audited_changes: { delivery_revision: [ previous_revision, invitation.delivery_revision ] },
            metadata: {
              invitation_id: invitation.id,
              request_digest:,
              delivery_revision: invitation.delivery_revision
            }
          )
          outcome = success(Result.new(record: invitation, token:, replayed: false))
        end
        outcome
      rescue ActiveRecord::RecordInvalid => exception
        failure(Core::BusinessError.new(
          I18n.t("organizations.membership_invitation.errors.invalid"),
          code: "membership_invitation_invalid",
          status: :unprocessable_entity,
          errors: exception.record.errors.to_hash
        ))
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
        actor && Organizations::MembershipPolicy.new(actor, invitation).update?
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
          namespace: "organizations/membership-invitation-resend/#{invitation.id}/#{actor.id}",
          value: key.to_s
        )
      end

      def request_digest_for
        Core::KeyedDigest.digest(
          namespace: "organizations/membership-invitation-resend-request",
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

        result = Expire.call(
          organization_id: invitation.organization_id,
          contact_digest: invitation.contact_digest,
          at:,
          limit: 1
        )
        raise result.error if result.failure?
      end

      def publish_delivery!
        key = Core::KeyedDigest.digest(
          namespace: "organizations/membership-invitation-delivery",
          value: "#{invitation.id}:#{invitation.delivery_revision}"
        )
        result = Core::Outbox::Publish.call(
          topic: "organizations",
          event_type: "organizations.membership_invitation.delivery_requested",
          aggregate: invitation,
          payload: { invitation_id: invitation.id, delivery_revision: invitation.delivery_revision },
          idempotency_key: key
        )
        raise result.error if result.failure?
      end

      def error(key, status)
        Core::BusinessError.new(
          I18n.t("organizations.membership_invitation.errors.#{key}"),
          code: key.to_s,
          status:
        )
      end
    end
  end
end
