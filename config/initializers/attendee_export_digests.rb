# frozen_string_literal: true

configured_keys = ENV["ATTENDEE_EXPORT_HMAC_KEYS"]
if Rails.env.production? && configured_keys.blank?
  raise I18n.t("core.private_attendee_exports.errors.hmac_keys_missing")
end

Rails.application.config.x.attendee_export_hmac_keys = configured_keys.present? ? JSON.parse(configured_keys) : nil
Rails.application.config.x.attendee_export_hmac_current_version =
  ENV.fetch("ATTENDEE_EXPORT_HMAC_CURRENT_VERSION", "v1")
