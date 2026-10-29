# frozen_string_literal: true

module Ticketing
  module Scanners
    # Shares privacy-safe request identity and audit-backed replay for scanner
    # invitation lifecycle commands without introducing a receipt table.
    module InvitationCommandSupport
      Result = Data.define(:record, :token, :pairing_code, :replayed) do
        def replayed? = replayed
      end

      private

      def command_key
        @command_key ||= Core::IdempotencyKey.new(idempotency_key_input)
      rescue ArgumentError
        nil
      end

      def request_digest(operation:, identity: {})
        Core::KeyedDigest.digest(
          namespace: "ticketing/scanner-invitation-command-request",
          value: ActiveSupport::JSON.encode(canonicalize(
            operation:, invitation_id: invitation.id, actor_id: actor.id, identity:
          ))
        )
      end

      def command_audit_key(operation:, key:)
        Core::KeyedDigest.digest(
          namespace: "ticketing/scanner-invitation-command-key/#{operation}/#{invitation.id}/#{actor.id}",
          value: key.to_s
        )
      end

      def replay_command(operation:, key:, digest:)
        audit_key = command_audit_key(operation:, key:)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit

        metadata = audit.metadata.deep_stringify_keys
        return failure(command_error(:idempotency_conflict, :conflict)) unless metadata["request_digest"] == digest

        success(Result.new(record: invitation, token: nil, pairing_code: nil, replayed: true))
      end

      def record_command_audit!(operation:, key:, digest:, action:, metadata: {})
        audit_key = command_audit_key(operation:, key:)
        safe_metadata = metadata.merge(request_digest: digest, invitation_id: invitation.id)
        result = Core::Audit::Record.call(
          audit_key:,
          action:,
          auditable_type: invitation.class.name,
          auditable_id: invitation.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: {},
          metadata: safe_metadata
        )
        raise result.error if result.failure?
      end

      def publish_delivery!(invitation)
        event_key = Core::KeyedDigest.digest(
          namespace: "ticketing/scanner-invitation-delivery",
          value: "#{invitation.id}:#{invitation.delivery_revision}"
        )
        result = Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.scanner_invitation.delivery_requested",
          aggregate: invitation,
          payload: { invitation_id: invitation.id, delivery_revision: invitation.delivery_revision },
          idempotency_key: event_key
        )
        raise result.error if result.failure?
      end

      def command_error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("ticketing.scanner.errors.#{key}"),
          code: key.to_s,
          status:,
          errors:
        )
      end

      def canonicalize(value)
        case value
        when Hash
          value.transform_keys(&:to_s).sort.to_h.transform_values { |nested| canonicalize(nested) }
        when Array
          value.map { |nested| canonicalize(nested) }
        else
          value.as_json
        end
      end
    end
  end
end
