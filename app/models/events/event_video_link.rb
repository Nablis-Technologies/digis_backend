# frozen_string_literal: true

module Events
  class EventVideoLink < Events::ApplicationRecord
    self.table_name = "events_event_video_links"
    self.inheritance_column = nil

    PROVIDERS = %w[youtube].freeze
    YOUTUBE_HOSTS = %w[
      youtube.com www.youtube.com m.youtube.com youtube-nocookie.com youtu.be
    ].freeze

    belongs_to :event, class_name: "Events::Event", inverse_of: :event_video_links
    belongs_to :created_by, class_name: "Core::User", inverse_of: :event_video_links

    validates :url, presence: true
    validates :created_by, presence: true
    validates :provider, presence: true, inclusion: { in: PROVIDERS }
    validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :youtube_url_format

    scope :for_event, ->(event) { where(event: event) }
    scope :ordered, -> { order(:position) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id created_by_id provider url title caption
         position created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event created_by]
    end

    private

    def youtube_url_format
      return if url.blank?

      uri = URI.parse(url)
      return errors.add(:url, "must be a YouTube link") unless YOUTUBE_HOSTS.include?(uri.host)

      valid = case uri.host
      when "youtu.be" then uri.path.match?(%r{\A/[\w-]{6,}\z})
      else uri.path.match?(%r{\A/(watch|shorts)/}) || uri.query.to_s.match?(/v=/)
      end
      errors.add(:url, "must be a YouTube video link") unless valid
    rescue URI::InvalidURIError
      errors.add(:url, "must be a valid URL")
    end
  end
end
