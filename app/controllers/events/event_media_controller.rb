# frozen_string_literal: true

module Events
  class EventMediaController < Events::ApplicationController
    include Core::Common
    include Core::CommandResponse

    self.model_class = Events::EventMedia
    self.parent_class = Events::Event
    self.parent_param = :event_id
    self.parent_association = :event_media
    self.default_serializer = Events::EventMediaSerializer

    def create
      @parent = Events::Event.find(params[:event_id])
      authorize @parent.event_media.new, :create?
      result = Events::Media::Create.call(
        event: @parent, actor: current_user,
        type: media_params[:type], position: media_params[:position],
        alt_text: media_params[:alt_text], caption: media_params[:caption],
        file: params[:file]
      )
      render_service_result(
        result,
        serializer_options: { serializer: Events::EventMediaSerializer },
        success_status: :created
      )
    end

    def update
      authorize @obj, :update?
      result = Events::Media::Update.call(
        media: @obj, actor: current_user,
        attributes: media_params, file: params[:file]
      )
      render_service_result(result, serializer_options: { serializer: Events::EventMediaSerializer })
    end

    def destroy
      authorize @obj, :destroy?
      result = Events::Media::Remove.call(media: @obj, actor: current_user)
      render_service_result(result, serializer_options: { serializer: Events::EventMediaSerializer })
    end

    def reorder
      authorize @parent.event_media.new, :update?
      result = Events::Media::Reorder.call(
        event: @parent, actor: current_user, ordered_ids: reorder_params
      )
      render_service_result(
        result,
        serializer_options: { serializer: Events::EventMediaSerializer },
        message: :"event_media.success.reorder"
      )
    end

    private

    def media_params
      params.require(:event_media).permit(:type, :position, :alt_text, :caption)
    end

    def reorder_params
      params.require(:ordered_ids)
    end
  end
end
