# frozen_string_literal: true

module Commercial
  # Narrow organizer command for selecting an allowed event-level fee payer.
  # Commercial::EventPayerSelections::Set rechecks scope and terms while locked.
  class EventPayerSelectionsController < Commercial::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present, only: :create
    before_action :find_event

    def index
      selection = ::Commercial::EventPayerSelection.new(event: @event)
      authorize selection, :index?, policy_class: ::Commercial::EventPayerSelectionPolicy
      selections = ::Commercial::EventPayerSelection.where(event: @event)
        .includes(:fee_component)
      render_success(data: selections, serializer_options: { serializer: ::Commercial::EventPayerSelectionSerializer })
    end

    def show
      selection = ::Commercial::EventPayerSelection.where(event: @event).find(params[:id])
      authorize selection, policy_class: ::Commercial::EventPayerSelectionPolicy
      render_success(data: selection, serializer_options: { serializer: ::Commercial::EventPayerSelectionSerializer })
    end

    def create
      selection = ::Commercial::EventPayerSelection.new(event: @event)
      authorize selection, :create?, policy_class: ::Commercial::EventPayerSelectionPolicy
      component = ::Commercial::FeeComponent.find(selection_params[:fee_component_id])
      result = ::Commercial::EventPayerSelections::Set.call(
        event: @event, fee_component: component, charged_to: selection_params[:charged_to],
        selected_by: current_user, idempotency_key:
      )
      render_service_result(result, serializer_options: { serializer: ::Commercial::EventPayerSelectionSerializer })
    end

    private

    def find_event
      @event = ::Events::Event.find(params[:event_id])
    end

    def selection_params
      params.require(:event_payer_selection).permit(:fee_component_id, :charged_to)
    end
  end
end
