# frozen_string_literal: true

module Events
  # The single, irreversible cancellation of an event. At most one row can exist
  # per event (enforced by a unique index), which is what makes cancellation a
  # one-way boundary.
  class EventCancellation < Events::ApplicationRecord
    self.table_name = "events_event_cancellations"
    self.inheritance_column = nil

    STATUSES = %w[initiated completed].freeze

    belongs_to :event, class_name: "Events::Event"
    belongs_to :initiated_by, class_name: "Core::User"

    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :idempotency_key, presence: true

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id initiated_by_id reason attendee_reason status
         cancelled_at created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event initiated_by]
    end
  end
end
