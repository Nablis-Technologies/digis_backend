# frozen_string_literal: true

module Ticketing
  # Immutable, language-neutral claims shared by QR verification, PNR lookup,
  # attendee-index sync, and the scanner validator. Only opaque identifiers,
  # admission shape, access grants, generation version, and expiry are allowed.
  CredentialClaims = Data.define(
    :kid, :cid, :tid, :eid, :mode, :slots, :entry_limit, :v, :accesses, :exp
  ) do
    # Reconstructs the same claim shape as QR verification from the active
    # attendee-index projection. The row is only an identifier source; the
    # admission service still reloads the credential and applies revocation,
    # schedule, zone, and usage rules before recording a result.
    def self.from_index_entry(entry, expires_at:)
      new(
        kid: Rails.application.config.x.ticketing_qr_current_kid.to_s,
        cid: entry.credential_id.to_s,
        tid: entry.ticket_id.to_s,
        eid: entry.event_id.to_s,
        mode: entry.credential_mode == "group" ? "group" : "individual",
        slots: Array(entry.slot_positions).map(&:to_i),
        entry_limit: entry.entry_limit.to_i,
        v: entry.generation_version.to_i,
        accesses: Array(entry.product_access_ids).map(&:to_s),
        exp: expires_at.to_time.to_i
      )
    end

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
