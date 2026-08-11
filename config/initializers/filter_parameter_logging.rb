# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :answer, :answers, :value, :consent, :consents, :content_sha256, :evidence_digest, :request_uuid, :reason_code,
  :qr_token, :lookup_code, :proof, :phone, :phone_hash, :identity_digest, :account_token, :holder_name, :payout,
  :provider_payload, :signature, :access_code, :code, :promotion_code, :code_ciphertext, :field_keys, :filters
]
