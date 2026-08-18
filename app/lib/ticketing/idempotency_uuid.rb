# frozen_string_literal: true

module Ticketing
  # Derives a stable UUID from a bounded idempotency key without persisting the
  # raw client value. Namespacing keeps keys for different append-only
  # commands and aggregates from colliding while preserving replay identity.
  module IdempotencyUuid
    module_function

    def from(key, namespace:)
      digest = Core::IdempotencyKey.new("#{namespace}:#{key}").digest
      [ digest[0, 8], digest[8, 4], "5#{digest[13, 3]}", "8#{digest[17, 3]}", digest[20, 12] ].join("-")
    end
  end
end
