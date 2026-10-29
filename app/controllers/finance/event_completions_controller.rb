# frozen_string_literal: true

module Finance
  # Exposes an authorized manual retry for the automatic event-completion
  # command. The controller never changes event dates or bypasses maturity.
  class EventCompletionsController < Finance::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present
    before_action :set_event

    def complete
      authorize @event, :complete?
      result = Finance::CompleteEvent.call(
        event: @event, actor: current_user, idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: { serializer: Events::EventSerializer, include: [] },
        message: :"finance.success.event_complete"
      )
    end

    private

    def set_event
      @event = Events::Event.find(params[:event_id])
    end
  end
end
