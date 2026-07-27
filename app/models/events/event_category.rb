# frozen_string_literal: true

module Events
  class EventCategory < Events::ApplicationRecord
    self.table_name = "events_event_categories"

    belongs_to :event, class_name: "Events::Event", inverse_of: :event_categories
    belongs_to :category, class_name: "Events::Category"

    validates :event, presence: true
    validates :category, presence: true
    validates :category_id, uniqueness: { scope: :event_id,
                                          message: :duplicate_category }
  end
end
