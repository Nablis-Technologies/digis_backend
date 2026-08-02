# frozen_string_literal: true

require "digest"

module Ticketing
  module AccessCodes
    # Creates an event-scoped access code and returns its plaintext once.
    class Create < Core::BaseService
      CodeResult = Data.define(:record, :plaintext)
      ATTRIBUTES = %i[label max_uses max_quantity_per_use starts_at expires_at active].freeze

      def initialize(ticket_type:, actor:, attributes:, idempotency_key:)
        @ticket_type = ticket_type
        @actor = actor
        @attributes = attributes.to_h.deep_symbolize_keys
        @raw_code = @attributes.delete(:code)
        @idempotency_key = idempotency_key
      end

      def call
        key = Core::IdempotencyKey.new(@idempotency_key)
        plaintext = Core::KeyedDigest.normalize(@raw_code)
        return failure_i18n("ticketing.access_code.errors.required") if plaintext.blank?
        request_digest = request_digest(plaintext)

        ActiveRecord::Base.transaction do
          Core::Database::AdvisoryLock.acquire!("ticketing-access-code-create", @ticket_type.id, key.digest)
          existing = @ticket_type.access_codes.lock.find_by(idempotency_key_digest: key.digest)
          return replay(existing, request_digest) if existing

          code = @ticket_type.access_codes.new(@attributes.slice(*ATTRIBUTES))
          code.code = plaintext
          code.code_digest = Ticketing::AccessCode.code_digest_for(
            event_id: @ticket_type.event_product.event_id,
            code: plaintext
          )
          code.idempotency_key_digest = key.digest
          code.creation_request_digest = request_digest
          return failure(Core::Error.new(code.errors.full_messages.join(", "))) unless code.valid?

          code.save!
          record_audit!(code)
          success(CodeResult.new(record: code, plaintext: plaintext))
        end
      rescue ArgumentError => error
        failure(Core::Error.new(error.message))
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(Core::Error.new(error.record.errors.full_messages.join(", ")))
      end

      private

      def request_digest(plaintext)
        payload = { code: plaintext, attributes: @attributes.slice(*ATTRIBUTES) }
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

      def replay(code, request_digest)
        raise Core::Error, I18n.t("idempotency.conflict") unless code.creation_request_digest == request_digest
        return failure(Core::Error.new(I18n.t("idempotency.replay_not_found"))) if code.code.blank?

        success(CodeResult.new(record: code, plaintext: code.code))
      end

      def record_audit!(code)
        Core::Audit::Record.call(
          audit_key: "ticketing-access-code-created-#{code.id}",
          action: "ticketing.access_code.created",
          auditable_type: code.class.name,
          auditable_id: code.id,
          actor_type: @actor&.class&.name,
          actor_id: @actor&.id,
          audited_changes: { ticket_type_id: code.ticket_type_id },
          metadata: { event_product_id: @ticket_type.event_product_id }
        )
      end
    end
  end
end
