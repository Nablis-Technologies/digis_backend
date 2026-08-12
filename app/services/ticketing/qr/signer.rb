# frozen_string_literal: true

require "base64"
require "json"

module Ticketing
  module Qr
    # Signs the scanner contract for one active credential. Only opaque
    # credential IDs, slot/access claims, and expiry are signed; consent,
    # registration answers, financial values, and acquisition history never
    # cross this boundary.
    class Signer
      def self.call(credential:)
        new(credential:).call
      end

      def initialize(credential:)
        @credential = credential
      end

      def call
        payload = claims
        signature = signing_key.sign(self.class.canonical_json(payload))
        envelope = payload.merge("sig" => Base64.strict_encode64(signature))

        Base64.urlsafe_encode64(JSON.generate(envelope), padding: false)
      end

      def self.canonical_json(value)
        JSON.generate(canonical_value(value))
      end

      def self.canonical_value(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested), result|
            result[key.to_s] = canonical_value(nested)
          end.sort.to_h
        when Array
          value.map { |nested| canonical_value(nested) }
        else
          value
        end
      end

      private

      attr_reader :credential

      def claims
        {
          "kid" => current_kid,
          "cid" => credential.id.to_s,
          "tid" => credential.ticket_id.to_s,
          "eid" => credential.event_id.to_s,
          "v" => generation.version,
          "mode" => generation.mode,
          "slots" => Array(credential.slot_positions).map(&:to_i),
          "entry_limit" => credential.entry_limit,
          "accesses" => product.product_accesses.map { |access| access.id.to_s },
          "exp" => expiration.to_i
        }
      end

      def signing_key
        Rails.application.config.x.ticketing_qr_signing_keys.fetch(current_kid)
      rescue KeyError
        raise Core::Error, I18n.t("ticketing.package_issuance.errors.qr_signing_key_missing")
      end

      def current_kid
        Rails.application.config.x.ticketing_qr_current_kid.to_s
      end

      def generation
        credential.credential_generation
      end

      def product
        credential.ticket.event_product
      end

      def expiration
        product.product_accesses.map { |access| access.event_date.ends_at }.compact.max ||
          raise(Core::Error, I18n.t("ticketing.package_issuance.errors.credential_expiry_missing"))
      end
    end
  end
end
