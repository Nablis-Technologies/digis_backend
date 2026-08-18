# frozen_string_literal: true

module Marketplace
  # Organizer resale-policy boundary. Configuration is persisted by the
  # command so disabling policy also closes open listings transactionally.
  class ResalePoliciesController < Marketplace::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present, only: :update
    before_action :load_ticket_type

    def show
      authorize @ticket_type, :show?, policy_class: ResalePolicyPolicy
      render_success(data: @ticket_type, serializer_options: { serializer: ResalePolicySerializer })
    end

    def update
      authorize @ticket_type, :update?, policy_class: ResalePolicyPolicy
      result = ConfigureTicketTypeResale.call(
        ticket_type: @ticket_type,
        actor: current_user,
        attributes: resale_policy_params.to_h,
        idempotency_key:
      )
      render_service_result(result, serializer_options: { serializer: ResalePolicySerializer })
    end

    private

    def load_ticket_type
      @ticket_type = Ticketing::TicketType.includes(event_product: :event).find(params[:ticket_type_id])
    end

    def resale_policy_params
      params.fetch(:resale_policy, ActionController::Parameters.new).permit(
        :resale_enabled, :resale_cutoff_seconds_before_start, :resale_price_cap_type,
        :resale_fixed_cap_minor, :resale_fixed_cap_currency, :resale_percentage_cap_bps,
        :max_completed_resales
      )
    end
  end
end
