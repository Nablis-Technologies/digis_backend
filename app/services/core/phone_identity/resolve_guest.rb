# frozen_string_literal: true

module Core
  module PhoneIdentity
    # Resolves a public guest identity and prevents self-service guest flows
    # from silently acting on an account that should authenticate.
    class ResolveGuest < Core::BaseService
      def initialize(phone:)
        @phone = phone
      end

      def call
        identity = ResolveOrCreate.call(phone:, actor: nil, allow_actor_mismatch: true)
        return identity if identity.failure?
        return failure(authentication_required) if authenticated_account?(identity.value.user)

        identity
      end

      private

      attr_reader :phone

      def authenticated_account?(user)
        user.password_digest.present? || user.verified_at.present?
      end

      def authentication_required
        Core::BusinessError.new(
          I18n.t("core.phone_identity.errors.guest_requires_authentication"),
          code: "guest_requires_authentication",
          status: :conflict
        )
      end
    end
  end
end
