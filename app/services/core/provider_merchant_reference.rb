# frozen_string_literal: true

require "digest"

module Core
  # Produces a deterministic opaque reference for providers with a stricter
  # merchant-reference contract than the client-facing idempotency key.
  class ProviderMerchantReference
    LENGTH = 20

    def self.call(provider:, subject_id:, idempotency_key:, attempt_number: nil)
      Digest::SHA256.hexdigest(
        [ "v1", provider.to_s.strip.downcase, subject_id, attempt_number, idempotency_key ].map(&:to_s).join("\0")
      ).first(LENGTH)
    end
  end
end
