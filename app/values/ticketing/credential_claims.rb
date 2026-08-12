# frozen_string_literal: true

module Ticketing
  # Immutable, language-neutral claims shared by QR verification, PNR lookup,
  # attendee-index sync, and the scanner validator. Only opaque identifiers,
  # admission shape, access grants, generation version, and expiry are allowed.
  CredentialClaims = Data.define(
    :kid, :cid, :tid, :eid, :mode, :slots, :entry_limit, :v, :accesses, :exp
  ) do
    def self.from_h(value)
      normalized = value.to_h.deep_symbolize_keys
      unless normalized.keys.sort == members.sort
        raise ArgumentError, I18n.t("ticketing.package_issuance.errors.invalid_credential_claims")
      end

      claims = new(**normalized)
      raise ArgumentError, I18n.t("ticketing.package_issuance.errors.invalid_credential_claims") unless claims.valid?

      claims
    rescue NoMethodError, TypeError
      raise ArgumentError, I18n.t("ticketing.package_issuance.errors.invalid_credential_claims")
    end

    def canonical_payload
      Ticketing::Qr::Signer.canonical_json(to_h)
    end

    def valid?
      strings_present? && valid_mode? && valid_slots? && valid_accesses? &&
        entry_limit.is_a?(Integer) && entry_limit.positive? &&
        v.is_a?(Integer) && v.positive? && exp.is_a?(Integer) && exp.positive?
    end

    private

    def strings_present?
      [ kid, cid, tid, eid ].all? { |value| value.is_a?(String) && value.present? }
    end

    def valid_mode?
      mode.is_a?(String) && %w[group individual].include?(mode)
    end

    def valid_slots?
      slots.is_a?(Array) && slots.all? { |position| position.is_a?(Integer) && position.positive? } &&
        slots.uniq.length == slots.length
    end

    def valid_accesses?
      accesses.is_a?(Array) && accesses.present? && accesses.all? { |access| access.is_a?(String) && access.present? }
    end
  end
end
