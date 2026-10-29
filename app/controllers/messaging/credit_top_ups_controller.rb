# frozen_string_literal: true

module Messaging
  # Starts and reads organization-owned credit purchase intents. Creation is
  # idempotent and delegates payment/provider state to Orders; this controller
  # never grants credits directly.
  class CreditTopUpsController < Messaging::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present, only: :create
    before_action :set_organization
    before_action :set_top_up, only: :show

    def create
      authorize CreditTopUp.new(organization: @organization), :create?
      result = CreateCreditTopUp.call(
        organization: @organization, requester: current_user,
        channel: top_up_params[:channel], quantity: top_up_params[:quantity].to_i,
        currency: top_up_params[:currency], country_code: top_up_params[:country_code],
        provider: top_up_params[:provider] || "chapa",
        payment_method: top_up_params[:payment_method] || "telebirr",
        idempotency_key:
      )
      render_service_result(result, success_status: :created,
        serializer_options: { top_up: { serializer: CreditTopUpSerializer } })
    end

    def show
      authorize @top_up, :show?
      render_success(
        data: @top_up,
        serializer_options: { serializer: CreditTopUpSerializer }
      )
    end

    private

    def set_organization
      @organization = Organizations::Organization.find(params[:organization_id])
    end

    def set_top_up
      @top_up = CreditTopUp.where(organization: @organization).includes(:rate_version).find(params[:id])
    end

    def top_up_params
      params.require(:credit_top_up).permit(
        :channel, :quantity, :currency, :country_code, :provider, :payment_method
      )
    end

    def serializer_profile
      { create: { fields: CreditTopUpPolicy::FIELDS, include: [] }, show: { fields: CreditTopUpPolicy::FIELDS, include: [] } }
    end
  end
end
