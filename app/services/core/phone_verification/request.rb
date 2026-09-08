# frozen_string_literal: true

require "securerandom"

module Core
  module PhoneVerification
    # Creates one expiring OTP challenge per idempotency key and sends the raw
    # code only through the injected delivery adapter.
    class Request < Core::BaseService
      TTL = 10.minutes

      def initialize(user:, phone:, purpose:, idempotency_key:)
        @user = user
        @phone = phone
        @purpose = purpose.to_s.strip
        @raw_idempotency_key = idempotency_key
      end

      def call
        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        normalized = Core::PhoneIdentity::ResolveOrCreate.normalize(phone)
        return failure(error(:phone_invalid, :unprocessable_entity)) if normalized.blank?
        return failure(error(:phone_mismatch, :forbidden)) unless normalized == normalized_user_phone

        code = SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")
        challenge, created = find_or_create_challenge(key, normalized, code)
        return failure(error(:delivery_failed, :failed_dependency)) if challenge.delivery_failed?
        return success(challenge) unless created

        delivery = Delivery.call(phone: user.phone, code:, challenge:)
        if delivery.failure?
          challenge.update!(status: "delivery_failed")
          return failure(delivery.error)
        end

        Core::Telemetry.instrument(
          "core.phone_verification.requested",
          aggregate_id: challenge.id,
          outcome: "sent"
        ) { }
        success(challenge)
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, :bad_request))
      rescue ActiveRecord::RecordNotUnique
        retry
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_challenge, :unprocessable_entity, errors: exception.record.errors.to_hash))
      end

      private

      attr_reader :user, :phone, :purpose, :raw_idempotency_key

      def find_or_create_challenge(key, normalized, code)
        existing = PhoneVerificationChallenge.find_by(
          user_id: user.id, purpose:, idempotency_key_digest: key.digest
        )
        return [ existing, false ] if existing

        [ PhoneVerificationChallenge.create!(
          user:,
          purpose:,
          phone_digest: Core::PhoneIdentity::ResolveOrCreate.digest_for(normalized),
          code_digest: code_digest(code),
          idempotency_key_digest: key.digest,
          status: "pending",
          attempts: 0,
          max_attempts: PhoneVerificationChallenge::DEFAULT_MAX_ATTEMPTS,
          expires_at: TTL.from_now
        ), true ]
      end

      def normalized_user_phone
        Core::PhoneIdentity::ResolveOrCreate.normalize(user.phone)
      end

      def code_digest(code)
        Core::KeyedDigest.digest(namespace: "core-phone-verification/#{user.id}/#{purpose}", value: code)
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
