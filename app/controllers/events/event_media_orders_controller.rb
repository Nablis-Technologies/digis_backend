# frozen_string_literal: true

module Events
  class EventMediaOrdersController < Events::ApplicationController
    include Core::CommandResponse

    before_action :set_event

    def reorder
      authorize @event.event_media.new, :update?
      result = Events::Media::Reorder.call(
        event: @event, actor: current_user, ordered_ids: reorder_params
      )
      render_service_result(result, serializer_options: { serializer: Events::EventMediaSerializer })
    end

    private

    def set_event
      @event = Events::Event.find(params[:event_id])
    end

    def reorder_params
      params.require(:ordered_ids)
    end
  end
end
