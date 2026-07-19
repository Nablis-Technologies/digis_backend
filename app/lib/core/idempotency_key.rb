# frozen_string_literal: true

require "digest"

module Core
  class IdempotencyKey
    MAX_LENGTH = 255

    attr_reader :value

    def initialize(raw_value)
      normalized = raw_value.to_s.strip
      raise ArgumentError, "idempotency key is required" if normalized.empty?
      raise ArgumentError, "idempotency key exceeds 255 bytes" if normalized.bytesize > MAX_LENGTH

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
