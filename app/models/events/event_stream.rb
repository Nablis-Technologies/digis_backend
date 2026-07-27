# frozen_string_literal: true

module Events
  class EventStream < Events::ApplicationRecord
    self.table_name = "events_event_streams"
    self.inheritance_column = nil

    STATUSES = %w[scheduled live ended disabled].freeze
    PROTECTIONS = %w[public soft_gated signed].freeze

    belongs_to :event_date, class_name: "Events::EventDate", inverse_of: :event_stream

    validates :provider, presence: true
    validates :access_protection, presence: true, inclusion: { in: PROTECTIONS }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :live_from, :live_until, presence: true
    validates :replay_available_until, presence: true, if: :replay_enabled?
    validate :live_requires_playback_id

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_date_id provider provider_stream_id provider_playback_id
         access_protection status live_from live_until replay_enabled
         replay_available_until max_concurrent_devices config
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event_date]
    end

    private

    def live_requires_playback_id
      return unless status == "live"

      errors.add(:provider_playback_id, "is required for a live stream") if provider_playback_id.blank?
    end
  end
end
