# frozen_string_literal: true

require "digest"
require "securerandom"

module Ticketing
  module Invitations
    # Creates an encrypted guest invitation and returns its link token once.
    class Create < Core::BaseService
      InvitationResult = Data.define(:record, :token)
      ATTRIBUTES = %i[name allowed_quantity expires_at].freeze

      def initialize(ticket_type:, actor:, attributes:, idempotency_key:)
        @ticket_type = ticket_type
        @actor = actor
        @attributes = attributes.to_h.deep_symbolize_keys
        @idempotency_key = idempotency_key
      end

      def call
        key = Core::IdempotencyKey.new(@idempotency_key)
        email = @attributes.delete(:email).to_s.strip.presence
        phone = @attributes.delete(:phone).to_s.strip.presence
        contact = email || phone
        return failure_i18n("ticketing.invitation.errors.contact_required") if contact.blank?
        request_digest = request_digest(email:, phone:)
        invitation = token = nil

        ActiveRecord::Base.transaction do
          Core::Database::AdvisoryLock.acquire!("ticketing-invitation-create", @ticket_type.id, key.digest)
          existing = @ticket_type.invitations.lock.find_by(idempotency_key_digest: key.digest)
          return replay(existing, request_digest) if existing

          token = SecureRandom.hex(32)
          invitation = @ticket_type.invitations.new(@attributes.slice(*ATTRIBUTES))
          invitation.created_by = @actor
          invitation.email = email if email
          invitation.phone = phone if phone
          invitation.token = token
          invitation.contact_digest = Ticketing::Invitation.contact_digest_for(
            event_id: @ticket_type.event_product.event_id,
            contact:
          )
          invitation.token_digest = Ticketing::Invitation.token_digest_for(
            event_id: @ticket_type.event_product.event_id,
            token:
          )
          invitation.idempotency_key_digest = key.digest
          invitation.creation_request_digest = request_digest

          return failure(Core::Error.new(invitation.errors.full_messages.join(", "))) unless invitation.valid?

          invitation.save!
          record_audit!(invitation)
          publish_outbox!(invitation)
        end
        success(InvitationResult.new(record: invitation, token: token))
      rescue ArgumentError => error
        failure(Core::Error.new(error.message))
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(Core::Error.new(error.record.errors.full_messages.join(", ")))
      end

      private

      def request_digest(email:, phone:)
        payload = { email:, phone:, attributes: @attributes.slice(*ATTRIBUTES) }
        Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(canonical(payload)))
      end

      def canonical(value)
        case value
        when Hash
          value.to_h.transform_keys(&:to_s).sort.to_h.transform_values { |nested| canonical(nested) }
        when Array
          value.map { |nested| canonical(nested) }
        else
          value.as_json
        end
      end

      def replay(invitation, request_digest)
        raise Core::Error, I18n.t("idempotency.conflict") unless invitation.creation_request_digest == request_digest
        return failure(Core::Error.new(I18n.t("idempotency.replay_not_found"))) if invitation.token.blank?

        success(InvitationResult.new(record: invitation, token: invitation.token))
      end

      def record_audit!(invitation)
        Core::Audit::Record.call(
          audit_key: "ticketing-invitation-created-#{invitation.id}",
          action: "ticketing.invitation.created",
          auditable_type: invitation.class.name,
          auditable_id: invitation.id,
          actor_type: @actor&.class&.name,
          actor_id: @actor&.id,
          audited_changes: { ticket_type_id: invitation.ticket_type_id },
          metadata: { event_product_id: @ticket_type.event_product_id }
        )
      end

      def publish_outbox!(invitation)
        Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.invitation.created",
          aggregate: invitation,
          payload: { invitation_id: invitation.id },
          idempotency_key: "ticketing-invitation-created-#{invitation.id}"
        )
      end
    end
  end
end
