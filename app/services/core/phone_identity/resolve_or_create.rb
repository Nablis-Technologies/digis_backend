# frozen_string_literal: true

module Core
  module PhoneIdentity
    # Resolves a canonical phone identity for self-service and manager-issued
    # complimentary tickets. The normal path requires the actor's verified
    # phone; the explicit manager-recipient path may create an unverified shadow
    # user and must only be called after the caller authorizes the manager.
    class ResolveOrCreate < Core::BaseService
      Identity = Data.define(:user, :digest)

      def initialize(phone:, actor:, allow_actor_mismatch: false)
        @phone = phone
        @actor = actor
        @allow_actor_mismatch = allow_actor_mismatch
      end

      def call
        normalized_phone = normalize(phone)
        return failure(error("phone_identity_invalid")) if normalized_phone.blank?
        return resolve_manager_recipient(normalized_phone) if allow_actor_mismatch

        return failure(error("phone_identity_unverified")) unless actor&.verified_at.present?
        return failure(error("phone_identity_mismatch")) unless normalized_phone == normalize(actor.phone)

        success(Identity.new(user: actor, digest: digest_for(normalized_phone)))
      end

      private

      attr_reader :phone, :actor, :allow_actor_mismatch

      def resolve_manager_recipient(normalized_phone)
        user = Core::User.find_or_initialize_by(phone: normalized_phone)
        user.save! if user.new_record?
        success(Identity.new(user:, digest: digest_for(normalized_phone)))
      rescue ActiveRecord::RecordInvalid
        failure(error("phone_identity_invalid"))
      end

      def normalize(value)
        raw = value.to_s.strip
        return if raw.blank? || !raw.match?(/\A\+?[\d\s-]+\z/)

        digits = raw.delete("^0-9")
        case digits
        when /\A2519\d{8}\z/
          digits
        when /\A09\d{8}\z/
          "251#{digits.delete_prefix("0")}"
        when /\A9\d{8}\z/
          "251#{digits}"
        end
      end

      def digest_for(value)
        OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, value)
      end

      def error(code)
        Core::BusinessError.new(
          I18n.t("ticketing.registrations.errors.#{code}"),
          code:,
          status: :unprocessable_entity
        )
      end
    end
  end
end
