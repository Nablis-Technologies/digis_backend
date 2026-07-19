# frozen_string_literal: true

module Core
  module Audit
    # The single, authoritative writer for audit evidence.
    #
    # Every audit (controller CRUD or synchronous command) funnels through
    # `call`, so the table has exactly one creation path. `audit_key` is the
    # idempotency boundary: the PostgreSQL unique index means a replay with the
    # same key returns the existing row, and a replay with different content
    # raises rather than silently overwriting history.
    class Record < Core::BaseService
      class SensitivePayload < Core::Error; end
      class ReplayConflict < Core::Error; end

      # Fields compared when deciding whether a replay matches the original.
      REPLAY_FIELDS = %w[
        action auditable_type auditable_id actor_type actor_id audited_changes metadata
        request_uuid ip_address user_agent
      ].freeze

      # Keys whose presence anywhere in the payload would leak secrets. Auditors
      # and logs must never carry these out of the trust boundary.
      FORBIDDEN_KEY_PATTERNS = [
        /password/i,
        /(^|_)token($|_)/i,
        /secret/i,
        /ciphertext/i,
        /(^|_)qr($|_)/i,
        /(^|_)pnr($|_)/i,
        /lookup_code/i,
        /account_number/i,
        /provider_payload/i,
        /webhook_body/i,
        /answer/i,
        /consent_content/i
      ].freeze

      def initialize(audit_key:, action:, auditable_type:, auditable_id:, actor_type: nil,
        actor_id: nil, audited_changes: {}, metadata: {}, request_uuid: nil,
        ip_address: nil, user_agent: nil)
        @attributes = {
          audit_key:,
          action: action.to_s,
          auditable_type:,
          auditable_id:,
          actor_type:,
          actor_id:,
          audited_changes: audited_changes.presence || {},
          metadata: metadata.presence || {},
          request_uuid:,
          ip_address:,
          user_agent:
        }
      end

      def call
        validate_identity!
        validate_payload!
        audit = create_or_find_audit
        validate_replay!(audit)
        success audit
      end

      private

      def validate_identity!
        fail ArgumentError, "audit_key is required" if @attributes[:audit_key].blank?
        fail ArgumentError, "action is required" if @attributes[:action].blank?
        fail ArgumentError, "auditable_type is required" if @attributes[:auditable_type].blank?
        fail ArgumentError, "auditable_id is required" if @attributes[:auditable_id].blank?
        if @attributes[:actor_type].present? != @attributes[:actor_id].present?
          fail ArgumentError, "actor_type and actor_id must be present together"
        end
      end

      # Recursive scan so forbidden keys hidden inside nested Hashes/Arrays are
      # still caught, not just at the top level.
      def validate_payload!
        keys = nested_keys(@attributes.slice(:audited_changes, :metadata))
        forbidden = keys.select do |key|
          FORBIDDEN_KEY_PATTERNS.any? { |pattern| pattern.match?(key) }
        end.uniq
        return if forbidden.empty?

        fail SensitivePayload, "audit payload contains forbidden keys: #{forbidden.join(', ')}"
      end

      def create_or_find_audit
        Core::AuditLog.create!(@attributes)
      rescue ActiveRecord::RecordNotUnique
        Core::AuditLog.find_by!(audit_key: @attributes.fetch(:audit_key))
      end

      # A replay must produce byte-for-byte the same canonical payload as the
      # original; otherwise it is a bug (two distinct events sharing a key).
      def validate_replay!(audit)
        expected = canonical(@attributes.stringify_keys.slice(*REPLAY_FIELDS))
        actual = canonical(audit.attributes.slice(*REPLAY_FIELDS))
        return if expected == actual

        fail ReplayConflict, "audit_key was already used for a different payload"
      end

      def canonical(value)
        ActiveSupport::JSON.decode(ActiveSupport::JSON.encode(value))
      end

      def nested_keys(value)
        case value
        when Hash
          value.flat_map { |key, nested| [ key.to_s, *nested_keys(nested) ] }
        when Array
          value.flat_map { |nested| nested_keys(nested) }
        else
          []
        end
      end
    end
  end
end
