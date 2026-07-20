# frozen_string_literal: true

module Events
  class EventSetting < Events::ApplicationRecord
    self.table_name = "events_event_settings"

    belongs_to :event, class_name: "Events::Event", inverse_of: :event_setting

    validates :event, presence: true
    validate :config_must_be_json_object

    private

    def config_must_be_json_object
      return if config.is_a?(Hash)

      errors.add(:config, I18n.t("events.event_setting.errors.config_must_be_object"))
    end
  end
end
