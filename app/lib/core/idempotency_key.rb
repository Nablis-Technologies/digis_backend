# frozen_string_literal: true

require "digest"

module Core
  class IdempotencyKey
    MAX_LENGTH = 255

    attr_reader :value

    def initialize(raw_value)
      normalized = raw_value.to_s.strip
      raise ArgumentError, I18n.t("core.errors.idempotency_key_required") if normalized.empty?
      raise ArgumentError, I18n.t("core.errors.idempotency_key_too_long") if normalized.bytesize > MAX_LENGTH

      @value = normalized.freeze
      freeze
    end

    def to_s
      value
    end

    def digest
      Digest::SHA256.hexdigest(value)
    end
  end
end
