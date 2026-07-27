# frozen_string_literal: true

module Events
  class EventVideoLinksController < Events::ApplicationController
    include Core::Common
    include Core::AuditableController

    self.model_class = Events::EventVideoLink
    self.parent_class = Events::Event
    self.parent_param = :event_id
    self.parent_association = :event_video_links
    self.default_serializer = Events::EventVideoLinkSerializer

    auditable on: %i[create update destroy]

    private

    def model_params
      params.require(:event_video_link)
            .permit(:url, :title, :caption, :position, :provider)
            .merge(created_by_id: current_user.id)
    end
  end
end
