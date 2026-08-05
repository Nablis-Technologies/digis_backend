# frozen_string_literal: true

require "digest"

module Catalog
  module Promotions
    # Shared canonicalization, locking, and audit-replay behavior for promotion
    # commands.
    #
    # Commands use these helpers to produce stable request digests, serialize
    # idempotency keys, and reject a key reused with different request data.
    module CommandSupport
      private

      def normalize_hash(value)
        value.to_h.deep_symbolize_keys
      end

      def normalize_product_ids(value)
        return if value.nil?
        return value.compact.map(&:to_s).uniq.sort if value.is_a?(Array)

        raise Core::Error, I18n.t("catalog.promotion.errors.invalid_product_ids")
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

      def request_digest(payload)
        Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(canonical(payload)))
      end

      def idempotency_digest(key)
        Digest::SHA256.hexdigest(key.to_s.strip)
      end

      def require_idempotency_key!(key)
        return if key.present?

        raise Core::Error, I18n.t("catalog.promotion.errors.idempotency_key_required")
      end

      def command_lock!(operation, scope, key)
        Core::Database::AdvisoryLock.acquire!("catalog-promotion", operation, scope, idempotency_digest(key))
      end

      def command_audit_key(operation, scope, key)
        "catalog-promotion-#{operation}-#{scope}-#{idempotency_digest(key)}"
      end

      def replay_metadata(audit_key, digest)
        audit = Core::AuditLog.find_by(audit_key: audit_key)
        return unless audit

        metadata = audit.metadata.deep_symbolize_keys
        return metadata if metadata[:request_digest] == digest

        raise Core::Error, I18n.t("catalog.promotion.errors.idempotency_conflict")
      end

      def record_command_audit!(audit_key:, action:, auditable:, actor:, request_digest:, metadata:, audited_changes:)
        Core::Audit::Record.call(
          audit_key:,
          action:,
          auditable_type: auditable.class.name,
          auditable_id: auditable.id,
          actor_type: actor&.class&.name,
          actor_id: actor&.id,
          audited_changes:,
          metadata: metadata.merge(request_digest:)
        )
      end

      def promotion_error(record)
        Core::Error.new(record.errors.full_messages.join(", "))
      end

      def attribute_changes(before, after)
        before.each_with_object({}) do |(attribute, previous), changes|
          current = after[attribute]
          changes[attribute] = [ previous, current ] if previous != current
        end
      end
    end
  end
end
