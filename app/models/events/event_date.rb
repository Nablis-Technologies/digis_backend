# frozen_string_literal: true

module Events
  class EventDate < Events::ApplicationRecord
    self.table_name = "events_event_dates"
    self.inheritance_column = nil

    STATUSES = %w[scheduled postponed cancelled completed].freeze

    belongs_to :event, class_name: "Events::Event", inverse_of: :event_dates
    belongs_to :venue, class_name: "Events::Venue", optional: true

    has_many :event_participants, class_name: "Events::EventParticipant",
             dependent: :destroy, inverse_of: :event_date
    has_one :event_stream, class_name: "Events::EventStream",
            dependent: :destroy, inverse_of: :event_date
    has_many :access_zones, class_name: "Events::AccessZone",
             dependent: :destroy, inverse_of: :event_date

    validates :starts_at, :ends_at, presence: true
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :held_venue_count, :issued_venue_count,
              numericality: { greater_than_or_equal_to: 0 }
    validates :source_key, uniqueness: { scope: :event_id, allow_nil: true }
    validate :ends_at_after_starts_at
    validate :doors_at_before_or_equal_starts_at
    validate :venue_counts_within_capacity

    scope :for_event, ->(event) { where(event: event) }
    scope :chronological, -> { order(:starts_at) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id venue_id name doors_at starts_at ends_at status
         venue_capacity held_venue_count issued_venue_count source_key
         created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event venue]
    end

    private

    def ends_at_after_starts_at
      return if ends_at.blank? || starts_at.blank?

      errors.add(:ends_at, "must be after starts_at") if ends_at <= starts_at
    end

    def doors_at_before_or_equal_starts_at
      return if doors_at.blank? || starts_at.blank?

      errors.add(:doors_at, "must be before or at starts_at") if doors_at > starts_at
    end

    def venue_counts_within_capacity
      return if venue_capacity.blank?

      total = (held_venue_count || 0) + (issued_venue_count || 0)
      if total > venue_capacity
        errors.add(:base, "held plus issued venue count exceeds capacity")
      end
    end
  end
end
