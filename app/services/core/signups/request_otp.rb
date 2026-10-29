# frozen_string_literal: true

module Core
  module Signups
    # Resolves the phone identity used by signup, then requests a purpose-bound
    # OTP without returning identity information to the caller.
    class RequestOtp < Core::BaseService
      PURPOSE = "account_signup"

      def initialize(phone:, idempotency_key:)
        @phone = phone
        @idempotency_key = idempotency_key
      end

      def call
        identity = Core::PhoneIdentity::ResolveOrCreate.call(
          phone:,
          actor: nil,
          allow_actor_mismatch: true
        )
        return failure(identity.error) if identity.failure?

        Core::PhoneVerification::Request.call(
          user: identity.value.user,
          phone:,
          purpose: PURPOSE,
          idempotency_key:
        )
      rescue ActiveRecord::RecordNotUnique
        retry
      end

      private

      attr_reader :phone, :idempotency_key
    end
  end
end
