# frozen_string_literal: true

module Events
  class EventParticipant < Events::ApplicationRecord
    self.table_name = "events_event_participants"
    self.inheritance_column = nil

    TYPES = %w[performer speaker host instructor panelist team guest].freeze

    belongs_to :event, class_name: "Events::Event", inverse_of: :event_participants
    belongs_to :event_date, class_name: "Events::EventDate",
               inverse_of: :event_participants, optional: true

    validates :name, presence: true
    validates :type, presence: true, inclusion: { in: TYPES }
    validates :display_order, numericality: { only_integer: true }
    validate :event_date_belongs_to_event

    scope :for_event, ->(event) { where(event: event) }
    scope :ordered, -> { order(:display_order) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id event_date_id artist_id name type description
         display_order metadata created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event event_date]
    end

    private

    def event_date_belongs_to_event
      return if event_date_id.blank? || event_id.blank?

      unless event_date&.event_id == event_id
        errors.add(:event_date, "must belong to the same event")
      end
    end
  end
end
