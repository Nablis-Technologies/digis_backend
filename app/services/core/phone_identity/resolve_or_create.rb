# frozen_string_literal: true

module Core
  module PhoneIdentity
    # Resolves the verified actor's canonical phone identity. There is no OTP
    # challenge service yet, so this command must not create or link an account
    # for a phone the authenticated actor has not already verified.
    class ResolveOrCreate < Core::BaseService
      Identity = Data.define(:user, :digest)

      def initialize(phone:, actor:)
        @phone = phone
        @actor = actor
      end

      def call
        normalized_phone = normalize(phone)
        return failure(error("phone_identity_invalid")) if normalized_phone.blank?
        return failure(error("phone_identity_unverified")) unless actor&.verified_at.present?
        return failure(error("phone_identity_mismatch")) unless normalized_phone == normalize(actor.phone)

        success(Identity.new(user: actor, digest: digest_for(normalized_phone)))
      end

      private

      attr_reader :phone, :actor

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
