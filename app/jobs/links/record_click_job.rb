# frozen_string_literal: true

module Links
  # Records privacy-limited click metadata after redirect success. Analytics
  # failure never changes the already-committed redirect decision.
  class RecordClickJob < ApplicationJob
    queue_as :default

    discard_on ActiveRecord::RecordNotFound

    def perform(short_link_id, referrer: nil, device_type: nil, country: nil, clicked_at: Time.current)
      Links::ShortLinkClick.create!(
        short_link_id:,
        referrer: sanitized_referrer(referrer),
        device_type: device_type.to_s.presence,
        country: country.to_s.upcase.presence,
        clicked_at:
      )
    end

    private

    def sanitized_referrer(value)
      return if value.blank?
      return if value.to_s.bytesize > 2_048

      uri = URI.parse(value.to_s)
      return unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      uri.origin
    rescue URI::InvalidURIError
      nil
    end
  end
end
