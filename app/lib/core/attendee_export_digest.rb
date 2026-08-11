# frozen_string_literal: true

require "openssl"

module Core
  # Versioned HMACs retained for the lifetime of attendee-export tombstones.
  module AttendeeExportDigest
    DEFAULT_VERSION = "v1"

    module_function

    def current_version
      Rails.application.config.x.attendee_export_hmac_current_version.presence || DEFAULT_VERSION
    end

    def versions
      key_ring.keys.sort
    end

    def key_ring
      configured = Rails.application.config.x.attendee_export_hmac_keys
      return configured.stringify_keys if configured.present?

      { DEFAULT_VERSION => Rails.application.secret_key_base }
    end

    def digest(namespace:, value:, version: current_version)
      key = key_ring.fetch(version.to_s) do
        fail ArgumentError, I18n.t("ticketing.attendee_exports.errors.hmac_key_version_unavailable")
      end
      derived_key = OpenSSL::HMAC.digest("SHA256", key, namespace.to_s)
      OpenSSL::HMAC.hexdigest("SHA256", derived_key, value.to_s.strip)
    end
  end
end
