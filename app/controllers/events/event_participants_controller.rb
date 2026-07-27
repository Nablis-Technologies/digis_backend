# frozen_string_literal: true

module Events
  class EventParticipantsController < Events::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::EventParticipant
    self.parent_class = Events::Event
    self.parent_param = :event_id
    self.parent_association = :event_participants
    self.default_serializer = Events::EventParticipantSerializer

    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:event_participant).permit(
        :event_date_id, :artist_id, :name, :type, :description, :display_order
      )
    end
  end
end
