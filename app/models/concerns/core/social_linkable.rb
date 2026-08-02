module Core
  module SocialLinkable
    extend ActiveSupport::Concern

    VALID_SOCIAL_PLATFORMS = %w[
      instagram twitter tiktok youtube facebook website
      spotify soundcloud apple_music telegram whatsapp discord
    ].freeze

    MAX_SOCIAL_LINKS = 10
    MAX_URL_LENGTH = 2048

    included do
      before_validation :normalize_social_links
      validate :validate_social_links
    end

    private

    def normalize_social_links
      return if social_links.blank?
      self.social_links = social_links.transform_keys(&:to_s).transform_values { |v| v.to_s.strip }
    end

    def validate_social_links
      return if social_links.blank?

      if social_links.size > MAX_SOCIAL_LINKS
        errors.add(:social_links, I18n.t("social_link.errors.max_platforms", maximum: MAX_SOCIAL_LINKS))
        return
      end

      invalid_keys = social_links.keys - VALID_SOCIAL_PLATFORMS
      if invalid_keys.any?
        errors.add(:social_links, I18n.t("social_link.errors.unsupported_platforms", platforms: invalid_keys.join(", ")))
        return
      end

      social_links.each do |platform, url|
        next if url.blank?
        unless valid_url?(url)
          errors.add(:social_links, I18n.t("social_link.errors.invalid_url", platform: platform))
        end
      end
    end

    def valid_url?(url)
      return false if url.length > MAX_URL_LENGTH
      uri = URI.parse(url)
      return false unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      return false if uri.host.blank? || uri.host.include?(" ")
      true
    rescue URI::InvalidURIError
      false
    end
  end
end
