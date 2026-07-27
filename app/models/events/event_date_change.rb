# frozen_string_literal: true

module Events
  # Append-only record of a single schedule change. Rows are never updated;
  # each reschedule writes a fresh, immutable old/new snapshot.
  class EventDateChange < Events::ApplicationRecord
    self.table_name = "events_event_date_changes"
    self.inheritance_column = nil

    CHANGE_TYPES = %w[reschedule].freeze

    belongs_to :event, class_name: "Events::Event"
    belongs_to :event_date, class_name: "Events::EventDate"
    belongs_to :scheduled_by, class_name: "Core::User"

    validates :change_type, presence: true, inclusion: { in: CHANGE_TYPES }
    validates :old_start_at, :old_end_at, :new_start_at, :new_end_at, presence: true

    # Append-only: snapshots are created but never edited or deleted.
    before_update :prevent_mutation
    before_destroy :prevent_mutation

    def prevent_mutation
      raise ActiveRecord::ReadOnlyRecord, "EventDateChange is append-only"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id event_date_id change_type old_start_at old_end_at
         new_start_at new_end_at scheduled_by_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event event_date scheduled_by]
    end
  end
end
