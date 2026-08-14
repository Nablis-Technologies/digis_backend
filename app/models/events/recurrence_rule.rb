# frozen_string_literal: true

module Events
  class RecurrenceRule < Events::ApplicationRecord
    self.table_name = "events_recurrence_rules"
    self.inheritance_column = nil

    belongs_to :event, class_name: "Events::Event", inverse_of: :recurrence_rule

    before_destroy :destroy_generated_dates

    validates :rrule, :timezone, :dtstart_local, presence: true
    validates :duration_seconds,
              numericality: { greater_than: 0, only_integer: true }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id rrule timezone dtstart_local duration_seconds
         generated_until active exdates rdates created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event]
    end

    private

    # Removing a recurrence rule must also remove the dates it generated,
    # otherwise they orphan (and a recreated rule would duplicate them).
    def destroy_generated_dates
      dates = event.event_dates
                  .where("source_key LIKE ?", "recurrence-#{id}-%")
                  .preload(:event_participants, :access_zones, :event_stream, :refund_items)
                  .to_a
      dates.each(&:destroy!)
    end
  end
end
