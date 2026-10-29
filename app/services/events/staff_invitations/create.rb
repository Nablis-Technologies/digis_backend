# frozen_string_literal: true

require "securerandom"

module Events
  module StaffInvitations
    class Create < Core::BaseService
      Result = Data.define(:record, :token, :replayed) do
        def replayed? = replayed
      end

      INVITATION_TTL = 7.days

      def initialize(event:, actor:, role:, idempotency_key:, ip_address:, phone: nil, email: nil,
        assignment_expires_at: nil, at: Time.current)
        @event = event
        @actor = actor
        @role = role.to_s
        @idempotency_key_input = idempotency_key
        @ip_address = ip_address
        @phone = phone
        @email = email
        @assignment_expires_at = assignment_expires_at
        @at = at.to_time.utc
      end

      def call
        key = idempotency_key
        return failure(error(:invalid_idempotency_key, :bad_request)) unless key
        return failure(error(:invalid_role, :unprocessable_entity)) unless StaffInvitation::ROLES.include?(role)
        return failure(error(:event_not_invitable, :conflict)) if event.status.in?(%w[cancelled completed])

        contact = invitation_contact
        return failure(contact) if contact.is_a?(Core::Error)
        return failure(error(:staff_invitation_window_invalid, :unprocessable_entity)) if invalid_assignment_expiry?
        return failure(error(:invitation_forbidden, :forbidden)) unless authorized?

        create_key_digest = create_key_digest_for(key)
        request_digest = request_digest_for(contact:)
        result = nil

        StaffInvitation.transaction do
          Core::Database::AdvisoryLock.acquire_all!(
            [ "event-staff-invitation-contact", event.id, contact_digest(contact) ],
            [ "event-staff-invitation-create", event.id, actor.id, key.digest ]
          )
          event.lock!
          expire_prior_contact_invites!(contact)

          replay = replay_by_key(create_key_digest:, request_digest:)
          if replay
            result = replay
            next
          end

          throttle = Core::InvitationThrottle.call(
            actor_id: actor.id,
            contact_digest: contact.rate_limit_digest,
            ip_address:
          )
          unless throttle.success?
            result = failure(throttle.error)
            next
          end

          if StaffInvitation.pending.exists?(event_id: event.id, contact_digest: contact_digest(contact))
            result = failure(error(:invitation_already_pending, :conflict))
            next
          end

          invitation = build_invitation(contact:, create_key_digest:, request_digest:)
          unless invitation.valid?
            result = failure(Core::BusinessError.new(
              I18n.t("events.staff_assignment.errors.invitation_invalid"),
              code: "staff_invitation_invalid",
              status: :unprocessable_entity,
              errors: invitation.errors.to_hash
            ))
            next
          end

          invitation.save!
          record_creation_audit!(invitation)
          publish_delivery!(invitation)
          result = success(Result.new(record: invitation, token: invitation.claim_token_ciphertext, replayed: false))
        end
        result
      rescue ActiveRecord::RecordNotUnique
        replay_or_duplicate(create_key_digest:, request_digest:)
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

      attr_reader :event, :actor, :role, :idempotency_key_input, :ip_address, :phone, :email,
                  :assignment_expires_at, :at

      def idempotency_key
        Core::IdempotencyKey.new(idempotency_key_input)
      rescue ArgumentError
        nil
      end

      def invitation_contact
        return error(:invitation_contact_invalid, :unprocessable_entity) if email.present? && phone.present?
        if email.present?
          Core::InvitationContact.parse(email:)
          return error(:invitation_channel_not_enabled, :unprocessable_entity)
        end

        Core::InvitationContact.parse(phone:)
      rescue ArgumentError
        error(:invitation_contact_invalid, :unprocessable_entity)
      end

      def invalid_assignment_expiry?
        return false if assignment_expires_at.blank?

        expiry = Time.zone.parse(assignment_expires_at.to_s)
        expiry.nil? || expiry <= at
      rescue ArgumentError, TypeError
        true
      end

      def authorized?
        Events::AuthorizationResolver.can_assign?(actor, event, role)
      end

      def create_key_digest_for(key)
        Core::KeyedDigest.digest(
          namespace: "events/staff-invitation-create/#{event.id}/#{actor.id}",
          value: key.to_s
        )
      end

      def request_digest_for(contact:)
        payload = {
          event_id: event.id,
          actor_id: actor.id,
          role:,
          contact_type: contact.type,
          contact_digest: contact_digest(contact),
          assignment_expires_at: parsed_assignment_expiry&.iso8601(6)
        }
        Core::KeyedDigest.digest(
          namespace: "events/staff-invitation-create-request",
          value: ActiveSupport::JSON.encode(payload)
        )
      end

      def parsed_assignment_expiry
        return if assignment_expires_at.blank?

        Time.zone.parse(assignment_expires_at.to_s)&.utc
      end

      def contact_digest(contact)
        contact.digest_for(scope_type: StaffInvitation::CONTACT_DIGEST_SCOPE, scope_id: event.id)
      end

      def expire_prior_contact_invites!(contact)
        result = Expire.call(event_id: event.id, contact_digest: contact_digest(contact), limit: 1, at:)
        raise result.error if result.failure?
      end

      def replay_by_key(create_key_digest:, request_digest:)
        existing = StaffInvitation.lock.find_by(create_idempotency_key_digest: create_key_digest)
        return unless existing
        return failure(error(:idempotency_conflict, :conflict)) unless existing.create_request_digest == request_digest

        token = existing.pending? && existing.expires_at > at ? existing.claim_token_ciphertext : nil
        success(Result.new(record: existing, token:, replayed: true))
      end

      def replay_or_duplicate(create_key_digest:, request_digest:)
        replay = replay_by_key(create_key_digest:, request_digest:)
        return replay if replay

        failure(error(:invitation_already_pending, :conflict))
      end

      def build_invitation(contact:, create_key_digest:, request_digest:)
        token = SecureRandom.hex(32)
        StaffInvitation.new(
          event:,
          invited_by: actor,
          role:,
          contact_type: contact.type.to_s,
          contact_ciphertext: contact.normalized_value,
          contact_digest: contact_digest(contact),
          status: "pending",
          claim_token_ciphertext: token,
          claim_token_digest: StaffInvitation.claim_token_digest_for(token),
          delivery_status: "queued",
          delivery_revision: 1,
          delivery_attempts: 0,
          expires_at: at + INVITATION_TTL,
          assignment_expires_at: parsed_assignment_expiry,
          create_idempotency_key_digest: create_key_digest,
          create_request_digest: request_digest
        )
      end

      def record_creation_audit!(invitation)
        invitation.record_audit!(
          "events.staff_invitation.created",
          actor:,
          audited_changes: { role:, status: "pending" },
          metadata: { invitation_id: invitation.id, event_id: event.id }
        )
      end

      def publish_delivery!(invitation)
        outbox_key = Core::KeyedDigest.digest(
          namespace: "events/staff-invitation-delivery",
          value: "#{invitation.id}:#{invitation.delivery_revision}"
        )
        result = Core::Outbox::Publish.call(
          topic: "events",
          event_type: "events.staff_invitation.delivery_requested",
          aggregate: invitation,
          payload: { invitation_id: invitation.id, delivery_revision: invitation.delivery_revision },
          idempotency_key: outbox_key
        )
        raise result.error if result.failure?
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
