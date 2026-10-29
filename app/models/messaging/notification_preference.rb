# frozen_string_literal: true

module Messaging
  # Explicit user channel preference. Marketing consent is intentionally not
  # represented here; campaign messaging owns a separate consent boundary.
  class NotificationPreference < Messaging::ApplicationRecord
    self.table_name = "messaging_notification_preferences"

    CATEGORIES = Messaging::Notification::CATEGORIES
    CHANNELS = Messaging::NotificationDelivery::CHANNELS

    belongs_to :user, class_name: "Core::User", inverse_of: :notification_preferences

    # Missing rows are deliberately represented as unsaved enabled defaults;
    # reading preferences must not create audit or persistence side effects.
    def self.effective_for(user, stored: nil)
      stored ||= where(user_id: user.id)
      stored = stored.index_by { |preference| [ preference.category, preference.channel ] }
      CATEGORIES.product(CHANNELS).map do |category, channel|
        stored[[ category, channel ]] || new(user:, category:, channel:, enabled: true)
      end
    end

    before_validation :normalize_fields

    validates :user, :category, :channel, presence: true
    validates :category, inclusion: { in: CATEGORIES }
    validates :channel, inclusion: { in: CHANNELS }
    validates :enabled, inclusion: { in: [ true, false ] }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id user_id category channel enabled created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[user]
    end

    private

    def normalize_fields
      self.category = category.to_s.strip.downcase.presence
      self.channel = channel.to_s.strip.downcase.presence
    end
  end
end
