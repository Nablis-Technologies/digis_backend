# frozen_string_literal: true

require "uri/mailto"

module Core
  # A normalized invitation destination. It is an address, not a user lookup
  # or proof of contact ownership.
  class InvitationContact
    Contact = Data.define(:type, :normalized_value, :masked_value) do
      def digest_for(scope_type:, scope_id:)
        Core::KeyedDigest.digest(
          namespace: "staff-invitation/#{scope_type}/#{scope_id}/#{type}",
          value: normalized_value
        )
      end

      def rate_limit_digest
        Core::KeyedDigest.digest(
          namespace: "staff-invitation/rate-limit/#{type}",
          value: normalized_value
        )
      end
    end

    class << self
      def parse(email: nil, phone: nil)
        return email_contact(email) if email.present? && phone.blank?
        return phone_contact(phone) if phone.present? && email.blank?

        raise ArgumentError
      end

      private

      def email_contact(input)
        normalized = input.to_s.strip.downcase
        raise ArgumentError unless URI::MailTo::EMAIL_REGEXP.match?(normalized)

        local_part, domain = normalized.split("@", 2)
        Contact.new(type: :email, normalized_value: normalized, masked_value: "#{local_part.first}***@#{domain}")
      end

      def phone_contact(input)
        digits = Core::PhoneIdentity::ResolveOrCreate.normalize(input)
        raise ArgumentError if digits.blank?

        normalized = "+#{digits}"
        Contact.new(type: :phone, normalized_value: normalized, masked_value: mask_phone(normalized))
      end

      def mask_phone(value)
        "#{value.first(5)}***#{value.last(2)}"
      end
    end
  end
end
