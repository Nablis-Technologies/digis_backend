# frozen_string_literal: true

module Core
  # Provides one privacy-safe boundary for operational domain events. Callers
  # may emit measurements and identifiers from the allowlist, never secrets or
  # arbitrary request payloads.
  module Telemetry
    SAFE_KEYS = %i[
      command_id aggregate_type aggregate_id organization_id event_id provider
      outcome code count currency duration_ms batch_id device_id
    ].freeze
    NAME_PATTERN = /\A[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+\z/

    module_function

    def instrument(name, **payload, &block)
      unless name.is_a?(String) && NAME_PATTERN.match?(name)
        raise ArgumentError, I18n.t("core.errors.telemetry_invalid_event_name")
      end

      ActiveSupport::Notifications.instrument(
        "digis.#{name}",
        payload.symbolize_keys.slice(*SAFE_KEYS),
        &block
      )
    end
  end
end
