# frozen_string_literal: true

module Events
  class EventCancellationsController < Events::ApplicationController
    include Core::CommandResponse

    before_action :set_event
    before_action :ensure_idempotency_key_present, only: [ :create ]

    def create
      authorize Events::EventCancellation.new(event: @event), :create?
      result = Events::Cancellation::Initiate.call(
        event: @event,
        actor: current_user,
        reason: cancellation_params[:reason],
        attendee_reason: cancellation_params[:attendee_reason],
        idempotency_key: idempotency_key
      )
      render_service_result(
        result,
        serializer_options: { serializer: Events::EventCancellationSerializer },
        success_status: :created,
        message: :"events.cancellation.success.create"
      )
    end

    private

    def set_event
      @event = Events::Event.find(params[:event_id])
    end

    def cancellation_params
      params.fetch(:cancellation, {}).permit(:reason, :attendee_reason)
    end
  end
end
