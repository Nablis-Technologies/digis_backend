# frozen_string_literal: true

module Events
  class AccessZone < Events::ApplicationRecord
    self.table_name = "events_access_zones"
    self.inheritance_column = nil

    TYPES = %w[venue parking].freeze

    belongs_to :event, class_name: "Events::Event", inverse_of: :access_zones
    belongs_to :event_date, class_name: "Events::EventDate",
               inverse_of: :access_zones, optional: true

    validates :name, presence: true
    validates :code, presence: true, uniqueness: { scope: :event_id }
    validates :type, presence: true, inclusion: { in: TYPES }
    validates :sort_order, numericality: { only_integer: true }
    validate :event_date_belongs_to_event

    scope :for_event, ->(event) { where(event: event) }
    scope :active, -> { where(active: true) }
    scope :ordered, -> { order(:sort_order) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id event_date_id type name code active sort_order
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event event_date]
    end

    private

    def event_date_belongs_to_event
      return if event_date_id.blank? || event_id.blank?

      unless event_date&.event_id == event_id
         errors.add(:event_date, I18n.t("events.access_zone.errors.event_date_event_mismatch"))
      end
    end
  end
end
