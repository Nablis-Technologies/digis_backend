# frozen_string_literal: true

module Core
  # A validated decimal string that remains safe for Rails serialization while
  # emitting an exact JSON number when used by an explicit wire encoder.
  class JsonNumber < String
    DECIMAL = /\A(?:0|[1-9]\d*)(?:\.\d+)?\z/

    def initialize(value)
      normalized = value.to_s.sub(/\.0+\z/, "")
      raise ArgumentError unless normalized.match?(DECIMAL)

      super(normalized)
    end

    def to_json(*) = to_s
  end
end
