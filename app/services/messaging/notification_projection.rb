# frozen_string_literal: true

module Messaging
  # Reduces event data to a type-owned, canonical JSON projection. This is the
  # privacy boundary between durable outbox payloads and user-facing content.
  module NotificationProjection
    class UnsafeData < Core::Error; end

    FORBIDDEN_KEYS = %w[
      token qr pnr password secret credential provider contact email phone
    ].freeze

    module_function

    def call(type, data)
      definition = NotificationTypes.fetch(type)
      raise UnsafeData, I18n.t("messaging.errors.notification_data_object_required") unless data.is_a?(Hash)

      attributes = data.deep_stringify_keys
      unknown_keys = attributes.keys - definition.data_keys
      forbidden_keys = nested_keys(attributes) & FORBIDDEN_KEYS
      nested_object_keys = attributes.filter_map do |key, value|
        key if nested_hash?(value)
      end
      invalid_keys = (unknown_keys + forbidden_keys + nested_object_keys).uniq
      return deep_freeze(canonical(attributes)) if invalid_keys.empty?

      raise UnsafeData, I18n.t(
        "messaging.errors.unsafe_notification_data", keys: invalid_keys.join(", ")
      )
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

    def nested_hash?(value)
      case value
      when Hash
        true
      when Array
        value.any? { |nested| nested_hash?(nested) }
      else
        false
      end
    end

    def deep_freeze(value)
      case value
      when Hash
        value.each { |key, nested| deep_freeze(key); deep_freeze(nested) }
      when Array
        value.each { |nested| deep_freeze(nested) }
      end
      value.freeze
    end
  end
end
