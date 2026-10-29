# frozen_string_literal: true

module Messaging
  # Quotes a credit purchase without reserving or mutating account balance.
  # Authorization is evaluated against the requested organization before the
  # provider-facing top-up flow can be started.
  class CreditEstimatesController < Messaging::ApplicationController
    before_action :set_organization

    def create
      authorize CreditTopUp.new(organization: @organization), :estimate?
      result = EstimateCreditTopUp.call(
        organization: @organization,
        channel: estimate_params[:channel],
        quantity: estimate_params[:quantity].to_i,
        currency: estimate_params[:currency],
        country_code: estimate_params[:country_code]
      )
      render_service_result(result)
    end

    private

    def set_organization
      @organization = Organizations::Organization.find(params[:organization_id])
    end

    def estimate_params
      params.require(:credit_estimate).permit(:channel, :quantity, :currency, :country_code)
    end
  end
end
