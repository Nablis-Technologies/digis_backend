# frozen_string_literal: true

require "securerandom"

module Organizations
  module MembershipInvitations
    class Create < Core::BaseService
      Result = Data.define(:record, :token, :replayed) do
        def replayed? = replayed
      end

      INVITATION_TTL = 7.days

      def initialize(organization:, actor:, role:, idempotency_key:, ip_address:, phone: nil, email: nil,
        at: Time.current)
        @organization = organization
        @actor = actor
        @role = role.to_s
        @idempotency_key_input = idempotency_key
        @ip_address = ip_address
        @phone = phone
        @email = email
        @at = at.to_time.utc
      end

      def call
        key = idempotency_key
        return failure(error(:invalid_idempotency_key, :bad_request)) unless key
        return failure(error(:invalid_role, :unprocessable_entity)) unless MembershipInvitation::ROLES.include?(role)

        contact = invitation_contact
        return failure(contact) if contact.is_a?(Core::Error)

        return failure(error(:invitation_forbidden, :forbidden)) unless authorized?

        create_key_digest = create_key_digest_for(key)
        request_digest = request_digest_for(contact:)
        result = nil

        MembershipInvitation.transaction do
          Core::Database::AdvisoryLock.acquire_all!(
            [ "organization-membership-invitation-contact", organization.id, contact_digest(contact) ],
            [ "organization-membership-invitation-create", organization.id, actor.id, key.digest ]
          )
          organization.lock!
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

          if MembershipInvitation.pending.exists?(organization_id: organization.id,
            contact_digest: contact_digest(contact))
            result = failure(error(:invitation_already_pending, :conflict))
            next
          end

          invitation = build_invitation(contact:, create_key_digest:, request_digest:)
          unless invitation.valid?
            result = failure(Core::BusinessError.new(
              I18n.t("organizations.membership_invitation.errors.invalid"),
              code: "membership_invitation_invalid",
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

      attr_reader :organization, :actor, :role, :idempotency_key_input, :ip_address, :phone, :email, :at

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

      def authorized?
        return false unless actor

        record = MembershipInvitation.new(organization:, invited_by: actor, role:)
        Organizations::MembershipPolicy.new(actor, record).create?
      end

      def create_key_digest_for(key)
        Core::KeyedDigest.digest(
          namespace: "organizations/membership-invitation-create/#{organization.id}/#{actor.id}",
          value: key.to_s
        )
      end

      def request_digest_for(contact:)
        payload = {
          organization_id: organization.id,
          actor_id: actor.id,
          role:,
          contact_type: contact.type,
          contact_digest: contact_digest(contact)
        }
        Core::KeyedDigest.digest(
          namespace: "organizations/membership-invitation-create-request",
          value: ActiveSupport::JSON.encode(payload)
        )
      end

      def contact_digest(contact)
        contact.digest_for(scope_type: MembershipInvitation::CONTACT_DIGEST_SCOPE, scope_id: organization.id)
      end

      def expire_prior_contact_invites!(contact)
        result = Expire.call(
          organization_id: organization.id,
          contact_digest: contact_digest(contact),
          limit: 1,
          at:
        )
        raise result.error if result.failure?
      end

      def replay_by_key(create_key_digest:, request_digest:)
        existing = MembershipInvitation.lock.find_by(create_idempotency_key_digest: create_key_digest)
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
        MembershipInvitation.new(
          organization:,
          invited_by: actor,
          role:,
          contact_type: contact.type.to_s,
          contact_ciphertext: contact.normalized_value,
          contact_digest: contact_digest(contact),
          status: "pending",
          claim_token_ciphertext: token,
          claim_token_digest: MembershipInvitation.claim_token_digest_for(token),
          delivery_status: "queued",
          delivery_revision: 1,
          delivery_attempts: 0,
          expires_at: at + INVITATION_TTL,
          create_idempotency_key_digest: create_key_digest,
          create_request_digest: request_digest
        )
      end

      def record_creation_audit!(invitation)
        invitation.record_audit!(
          "organizations.membership_invitation.created",
          actor:,
          audited_changes: { role:, status: "pending" },
          metadata: { invitation_id: invitation.id, organization_id: organization.id }
        )
      end

      def publish_delivery!(invitation)
        outbox_key = Core::KeyedDigest.digest(
          namespace: "organizations/membership-invitation-delivery",
          value: "#{invitation.id}:#{invitation.delivery_revision}"
        )
        result = Core::Outbox::Publish.call(
          topic: "organizations",
          event_type: "organizations.membership_invitation.delivery_requested",
          aggregate: invitation,
          payload: { invitation_id: invitation.id, delivery_revision: invitation.delivery_revision },
          idempotency_key: outbox_key
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
