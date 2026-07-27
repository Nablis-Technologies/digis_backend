# frozen_string_literal: true

module Events
  class EventDatesController < Events::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::EventDate
    self.parent_class = Events::Event
    self.parent_param = :event_id
    self.parent_association = :event_dates
    self.default_serializer = Events::EventDateSerializer

    auditable on: %i[create update destroy]

    private

    # Creation may set the scheduling fields, but ordinary updates must not touch
    # starts_at/ends_at (those go through the schedule-change command), status
    # (date lifecycle), or the inventory-owned held/issued counters.
    def model_params
      if action_name == "create"
        params.require(:event_date).permit(
          :venue_id, :name, :doors_at, :starts_at, :ends_at, :venue_capacity
        )
      else
        params.require(:event_date).permit(:name)
      end
    end
  end
end
