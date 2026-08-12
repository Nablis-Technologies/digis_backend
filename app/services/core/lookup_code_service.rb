# frozen_string_literal: true

require "securerandom"

module Core
  # Generates the human-entered PNR used by the online and offline lookup
  # paths. The database remains authoritative for event-scoped uniqueness;
  # this service only performs a bounded pre-check to avoid ordinary retries.
  class LookupCodeService
    ALPHABET = "23456789CFGHJKMNPQRVWX".chars.freeze
    BODY_LENGTH = 7
    CODE_LENGTH = BODY_LENGTH + 1
    MAX_ATTEMPTS = 10

    class << self
      def generate(event_id, reserved_codes: nil)
        MAX_ATTEMPTS.times do
          code = generate_code
          available = if reserved_codes
            !reserved_codes.include?(code)
          else
            !Ticketing::Credential.exists?(event_id:, lookup_code: code)
          end
          return code if available
        end

        raise Core::Error, I18n.t("ticketing.package_issuance.errors.lookup_code_generation_failed")
      end

      # Normalizes operator input and rejects invalid check digits before the
      # lookup reaches the attendee index.
      def validate(raw_code)
        code = raw_code.to_s.upcase.gsub(/[^A-Z0-9]/, "")
        return unless code.length == CODE_LENGTH
        return unless code.chars.all? { |character| ALPHABET.include?(character) }
        return unless valid_check_digit?(code)

        code
      end

      private

      def generate_code
        body = Array.new(BODY_LENGTH) { ALPHABET.sample(random: SecureRandom) }.join
        body + check_digit(body)
      end

      def valid_check_digit?(code)
        code[-1] == check_digit(code[0...-1])
      end

      # Luhn mod-N over the approved alphabet, matching the scanner contract.
      def check_digit(body)
        sum = body.chars.reverse.each_with_index.sum do |character, index|
          value = ALPHABET.index(character)
          if index.odd?
            value
          else
            doubled = value * 2
            (doubled % ALPHABET.size) + (doubled / ALPHABET.size)
          end
        end

        ALPHABET[(ALPHABET.size - (sum % ALPHABET.size)) % ALPHABET.size]
      end
    end
  end
end
