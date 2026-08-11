# frozen_string_literal: true

module Ticketing
  # Routes each decision to exactly one command; authorization and idempotency
  # are enforced before the service can mutate the registration.
  class RegistrationDecisionsController < Ticketing::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present
    before_action :load_registration

    def approve
      authorize @registration, :approve?
      result = Ticketing::RegistrationDecisions::Approve.call(
        registration: @registration,
        actor: current_user,
        idempotency_key:
      )
      render_result(result)
    end

    def reject
      authorize @registration, :reject?
      result = Ticketing::RegistrationDecisions::Reject.call(
        registration: @registration,
        actor: current_user,
        reason: params[:reason],
        idempotency_key:
      )
      render_result(result)
    end

    def reconsider
      authorize @registration, :reconsider?
      result = Ticketing::RegistrationDecisions::Reconsider.call(
        registration: @registration,
        actor: current_user,
        decision: params.require(:decision),
        reason: params[:reason],
        idempotency_key:
      )
      render_result(result)
    end

    private

    def load_registration
      @registration = Ticketing::Registration
        .includes(:event, :user, ticket_type: :event_product)
        .find(params[:id])
    end

    def render_result(result)
      render_service_result(
        result,
        serializer_options: { serializer: Ticketing::RegistrationSerializer }
      )
    end
  end
end
