# frozen_string_literal: true

module Orders
  # Keeps the registration-release URL stable while delegating checkout
  # orchestration to the Orders module.
  class RegistrationCheckoutsController < Orders::ApplicationController
    before_action :ensure_idempotency_key_present, only: :create
    before_action :load_registration, only: :create

    def create
      authorize @registration, :release?
      result = Orders::ReleaseBuyerRegistration.call(
        registration_id: @registration.id,
        buyer: current_user,
        idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: { serializer: Ticketing::RegistrationSerializer }
      )
    end

    private

    def load_registration
      @registration = Ticketing::Registration.find(params[:id])
    end
  end
end
