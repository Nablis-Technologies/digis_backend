# frozen_string_literal: true

require "openssl"

module Core
  # Deterministic, keyed digest used for access codes and invitation
  # contacts/tokens. The `namespace` (typically an event id) scopes the derived
  # HMAC key so that identical plaintext yields different digests across events
  # and raw values are never comparable across namespaces. Plaintext is never
  # stored and must be kept out of logs by callers.
  module KeyedDigest
    module_function

    def digest(namespace:, value:)
      derived_key = OpenSSL::HMAC.digest("SHA256", Rails.application.secret_key_base, namespace.to_s)
      OpenSSL::HMAC.hexdigest("SHA256", derived_key, normalize(value))
    end

    def normalize(value)
      value.to_s.strip
    end
  end
end
