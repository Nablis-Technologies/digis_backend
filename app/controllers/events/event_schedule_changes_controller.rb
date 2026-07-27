# frozen_string_literal: true

module Events
  class EventScheduleChangesController < Events::ApplicationController
    include Core::CommandResponse

    before_action :set_event
    before_action :ensure_idempotency_key_present, only: [ :create ]

    def create
      authorize Events::EventDateChange.new(event: @event), :create?
      result = Events::Schedule::Change.call(
        event: @event,
        actor: current_user,
        changes: change_params[:changes] || [],
        idempotency_key: idempotency_key
      )
      render_service_result(
        result,
        serializer_options: { serializer: Events::EventDateChangeSerializer },
        success_status: :created,
        message: :"events.schedule_change.success.create"
      )
    end

    private

    def set_event
      @event = Events::Event.find(params[:event_id])
    end

    def change_params
      params.require(:schedule_change).permit(
        changes: [ :event_date_id, :new_start_at, :new_end_at, :change_type ]
      )
    end
  end
end
