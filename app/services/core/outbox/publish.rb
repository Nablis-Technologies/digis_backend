# frozen_string_literal: true

module Core
  module Outbox
    # Records an outbound event in the same transaction as the domain change.
    #
    # Idempotency contract:
    #   - Same key + same content  -> returns the existing row (no duplicate).
    #   - Same key + different content -> raises IdempotencyConflict.
    #   - Sensitive keys in the payload -> raises SensitivePayload (never stored).
    #
    # The returned event is committed with the caller's transaction, so it is
    # only visible once the business write succeeds.
    class Publish < Core::BaseService
      class SensitivePayload < Core::Error; end
      class IdempotencyConflict < Core::Error; end

      # Keys whose presence anywhere in the payload would leak secrets. Auditors
      # and dispatchers must never carry these out of the trust boundary.
      FORBIDDEN_KEYS = %w[answer consent_content qr_token pnr password account_number].freeze

      def initialize(topic:, event_type:, aggregate:, payload:, idempotency_key:)
        @topic = topic
        @event_type = event_type
        @aggregate = aggregate
        @payload = payload.deep_stringify_keys
        @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
      end

      def call
        validate_payload!
        # create_or_find_by! only assigns the block attributes when actually
        # creating; on a replay it returns the stored row unchanged.
        event = Core::OutboxEvent.create_or_find_by!(idempotency_key: @idempotency_key.to_s) do |row|
          row.assign_attributes(
            topic: @topic,
            event_type: @event_type,
            aggregate: @aggregate,
            payload: @payload,
            occurred_at: Time.current,
            available_at: Time.current
          )
        end
        verify_same_publication!(event)
        success(event)
      end

      private

      # Walk the payload tree so forbidden keys hidden inside nested Hashes/Arrays
      # are still caught, not just top-level ones.
      def validate_payload!
        forbidden = nested_keys(@payload) & FORBIDDEN_KEYS
        fail SensitivePayload, I18n.t(
          "core.errors.outbox_payload_forbidden_keys",
          keys: forbidden.join(", ")
        ) if forbidden.any?
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

      # Replaying the same key with different content is almost certainly a bug
      # (two distinct events sharing one idempotency key). Surface it loudly
      # rather than silently overwriting the original row.
      def verify_same_publication!(event)
        same = event.topic == @topic &&
          event.event_type == @event_type &&
          event.aggregate_type == @aggregate.class.base_class.name &&
          event.aggregate_id == @aggregate.id &&
          event.payload == @payload
        return if same

        fail IdempotencyConflict, I18n.t("core.errors.outbox_idempotency_conflict")
      end
    end
  end
end
