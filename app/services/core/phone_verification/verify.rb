# frozen_string_literal: true

require "json"

module Core
  module PhoneVerification
    # Consumes one OTP challenge under a row lock and returns a short-lived
    # signed proof for the subsequent guest-claim command.
    class Verify < Core::BaseService
      Result = Data.define(:challenge, :token)
      PROOF_PURPOSE = "core.phone_verification.proof"
      PROOF_TTL = 15.minutes

      def initialize(challenge:, code:)
        @challenge = challenge
        @code = code.to_s.strip
      end

      def call
        outcome = nil
        PhoneVerificationChallenge.transaction do
          challenge = PhoneVerificationChallenge.lock.find(@challenge.id)
          validation = validate(challenge)
          if validation
            outcome = failure(validation)
            next
          end

          if challenge.code_digest != code_digest(challenge)
            challenge.attempts += 1
            challenge.status = "exhausted" if challenge.attempts >= challenge.max_attempts
            challenge.save!
            outcome = failure(error(
              challenge.status == "exhausted" ? :attempts_exhausted : :code_invalid,
              :unprocessable_entity
            ))
            next
          end

          challenge.update!(status: "verified", verified_at: Time.current)
          Core::Telemetry.instrument(
            "core.phone_verification.verified",
            aggregate_id: challenge.id,
            outcome: "verified"
          ) { }
          outcome = success(Result.new(challenge:, token: proof_token(challenge)))
        end
        outcome
      rescue ActiveRecord::RecordNotFound
        failure(error(:challenge_not_found, :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_challenge, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      def self.verify_proof(token)
        payload = verifier.verify(token, purpose: PROOF_PURPOSE).deep_stringify_keys
        {
          challenge_id: payload.fetch("challenge_id").to_s,
          user_id: payload.fetch("user_id").to_s,
          phone_digest: payload.fetch("phone_digest").to_s
        }
      rescue ActiveSupport::MessageVerifier::InvalidSignature,
             ActiveSupport::MessageVerifier::InvalidMessage,
             KeyError,
             TypeError
        nil
      end

      private

      attr_reader :challenge, :code

      def validate(locked)
        return error(:verification_already_used, :conflict) if locked.verified?
        return error(:delivery_failed, :conflict) if locked.delivery_failed?
        if locked.expires_at <= Time.current
          locked.update!(status: "expired") if locked.pending?
          return error(:verification_expired, :conflict)
        end
        return error(:attempts_exhausted, :conflict) if locked.attempts >= locked.max_attempts
        return error(:code_format_invalid, :unprocessable_entity) unless code.match?(/\A\d{6}\z/)

        nil
      end

      def code_digest(locked)
        Core::KeyedDigest.digest(
          namespace: "core-phone-verification/#{locked.user_id}/#{locked.purpose}",
          value: code
        )
      end

      def proof_token(locked)
        self.class.verifier.generate(
          {
            "challenge_id" => locked.id.to_s,
            "user_id" => locked.user_id.to_s,
            "phone_digest" => locked.phone_digest
          },
          purpose: PROOF_PURPOSE,
          expires_at: PROOF_TTL.from_now
        )
      end

      def self.verifier
        @verifier ||= ActiveSupport::MessageVerifier.new(
          Rails.application.secret_key_base,
          digest: "SHA256",
          serializer: JSON
        )
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("auth.phone_verification.errors.#{key}"),
          code: key.to_s, status:, errors:
        )
      end
    end
  end
end
