# frozen_string_literal: true

require "base64"
require "json"

module Ticketing
  module Qr
    # Verifies the signed QR envelope and converts it into the same immutable
    # claims object used by PNR/manual lookup. Signature failures never expose
    # the payload to downstream validation or admission recording.
    class Verifier < Core::BaseService
      MAX_TOKEN_BYTES = 8.kilobytes

      def initialize(token:, now: Time.current, verify_keys: nil)
        @token = token.to_s
        @now = now
        @verify_keys = verify_keys
      end

      def call
        envelope = decode_envelope
        signature = envelope.delete("sig")
        return failure_for(:invalid_qr_token, "invalid_qr_token") unless signature.is_a?(String)

        verify_signature!(envelope, signature)
        claims = Ticketing::CredentialClaims.from_h(envelope)
        return failure_for(:expired_qr_token, "expired_qr_token") if claims.exp <= @now.to_i

        success(claims)
      rescue Ed25519::VerifyError
        failure_for(:invalid_qr_signature, "invalid_qr_signature")
      rescue UnknownKeyFailure
        failure_for(:unknown_qr_key, "unknown_qr_key")
      rescue MalformedTokenError
        failure_for(:invalid_qr_token, "invalid_qr_token")
      rescue ArgumentError => error
        failure_for(:invalid_credential_claims, "invalid_credential_claims", meta: { cause: error.class.name })
      rescue JSON::ParserError, TypeError, Encoding::CompatibilityError
        failure_for(:invalid_qr_token, "invalid_qr_token")
      end

      private

      def decode_envelope
        raise ArgumentError if @token.bytesize > MAX_TOKEN_BYTES

        decoded = Base64.urlsafe_decode64(@token)
        parsed = JSON.parse(decoded)
        raise ArgumentError unless parsed.is_a?(Hash)

        parsed
      rescue ArgumentError
        raise MalformedTokenError
      end

      def verify_signature!(payload, encoded_signature)
        kid = payload["kid"]
        verify_key = verify_keys.fetch(kid) { raise UnknownKeyError }
        signature = Base64.strict_decode64(encoded_signature)
        verify_key.verify(signature, Ticketing::Qr::Signer.canonical_json(payload))
      rescue UnknownKeyError
        raise UnknownKeyFailure
      rescue ArgumentError
        raise Ed25519::VerifyError
      end

      def verify_keys
        @verify_keys || Rails.application.config.x.ticketing_qr_verify_keys
      end

      def failure_for(key, code, meta: nil)
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.package_issuance.errors.#{key}"), code:, status: :unprocessable_entity, meta:
          )
        )
      end

      class UnknownKeyError < StandardError; end
      class UnknownKeyFailure < StandardError; end
      class MalformedTokenError < StandardError; end
    end
  end
end
