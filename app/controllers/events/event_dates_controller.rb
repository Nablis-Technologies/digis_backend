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

    def model_params
      params.require(:event_date).permit(
        :venue_id, :name, :doors_at, :starts_at, :ends_at, :status,
        :venue_capacity, :held_venue_count, :issued_venue_count
      )
    end
  end
end
