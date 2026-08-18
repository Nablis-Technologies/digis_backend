# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "ed25519"

# Loads rotating Ed25519 signing keys without putting private material in the
# repository. Production must supply an environment/credential mapping; the
# deterministic test/development fallback is deliberately not production-safe.
configured_keys = ENV["TICKETING_QR_SIGNING_KEYS"].presence ||
  Rails.application.credentials.dig(:ticketing, :qr_signing_keys)

signing_keys = if configured_keys.present?
  values = configured_keys.is_a?(String) ? JSON.parse(configured_keys) : configured_keys.to_h
  values.transform_keys(&:to_s).transform_values do |encoded_seed|
    Ed25519::SigningKey.new(Base64.strict_decode64(encoded_seed.to_s))
  end
elsif Rails.env.test? || Rails.env.development?
  seed = Digest::SHA256.digest("#{Rails.application.secret_key_base}:ticketing-qr:v1")
  { "v1" => Ed25519::SigningKey.new(seed) }
else
  raise "TICKETING_QR_SIGNING_KEYS must configure production Ed25519 seeds"
end

current_kid = ENV.fetch("TICKETING_QR_CURRENT_KID", "v1")
raise "TICKETING_QR_CURRENT_KID is not present in configured signing keys" unless signing_keys.key?(current_kid)

Rails.application.config.x.ticketing_qr_signing_keys = signing_keys.freeze
Rails.application.config.x.ticketing_qr_verify_keys = signing_keys.transform_values(&:verify_key).freeze
Rails.application.config.x.ticketing_qr_current_kid = current_kid.freeze
