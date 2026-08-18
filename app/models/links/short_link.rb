# frozen_string_literal: true

require "uri"

module Links
  # A feature-gated branded redirect to one allowlisted internal resource or a
  # validated HTTPS URL. The slug is never an authorization secret or QR value.
  class ShortLink < Links::ApplicationRecord
    self.table_name = "links_short_links"

    TARGET_TYPES = %w[event ticket organization].freeze
    RESERVED_SLUGS = %w[
      up events tickets organizations catalog scanner auth public health
      add_on_reports
    ].freeze
    MAX_SLUG_LENGTH = 100

    belongs_to :creator, class_name: "Core::User", optional: true
    has_many :clicks, class_name: "Links::ShortLinkClick", inverse_of: :short_link,
             dependent: :restrict_with_exception

    before_validation :normalize_fields

    validates :slug, presence: true, length: { maximum: MAX_SLUG_LENGTH },
                    format: { with: /\A[a-z0-9]+(?:[-_][a-z0-9]+)*\z/ }
    validates :target_type, inclusion: { in: TARGET_TYPES }, allow_nil: true
    validates :max_clicks, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :click_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :slug_not_reserved
    validate :exactly_one_target
    validate :custom_url_is_https
    validate :click_count_within_limit

    scope :by_slug, ->(slug) { where("lower(slug) = ?", slug.to_s.downcase) }

    def internal_target?
      target_type.present? && target_id.present?
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id slug target_type target_id creator_id canonical expires_at max_clicks click_count
         utm_source utm_medium utm_campaign created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[creator clicks]
    end

    private

    def normalize_fields
      self.slug = slug.to_s.strip.downcase.presence
      self.target_type = target_type.to_s.strip.downcase.presence
      self.custom_url = custom_url.to_s.strip.presence
    end

    def slug_not_reserved
      errors.add(:slug, :reserved) if RESERVED_SLUGS.include?(slug)
    end

    def exactly_one_target
      internal = target_type.present? && target_id.present?
      external = custom_url.present?
      return if internal ^ external

      errors.add(:base, :target_xor)
    end

    def custom_url_is_https
      return if custom_url.blank?

      uri = URI.parse(custom_url)
      valid = uri.is_a?(URI::HTTPS) && uri.host.present? && !uri.host.include?(" ")
      errors.add(:custom_url, :https_required) unless valid
    rescue URI::InvalidURIError
      errors.add(:custom_url, :https_required)
    end

    def click_count_within_limit
      return if max_clicks.blank? || click_count.to_i <= max_clicks

      errors.add(:click_count, :exceeds_maximum)
    end
  end
end
