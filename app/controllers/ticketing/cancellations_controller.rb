# frozen_string_literal: true

module Ticketing
  # Organizer cancellation is intentionally a thin command boundary. The
  # cancellation service owns suspension, refund creation, credential state,
  # locking, and idempotency; the controller only authorizes and renders it.
  class CancellationsController < Ticketing::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present
    before_action :load_ticket

    def create
      authorize @ticket, :cancel?, policy_class: Ticketing::TicketPolicy
      result = Ticketing::CancelPaidPackage.call(
        ticket: @ticket,
        actor: current_user,
        idempotency_key:,
        override_reason: cancellation_params[:override_reason]
      )
      render_service_result(
        result,
        serializer_options: { serializer: Orders::RefundSerializer }
      )
    end

    private

    def load_ticket
      @ticket = Ticketing::Ticket.includes(:event, :current_acquisition_order_item).find(params[:ticket_id])
    end

    def cancellation_params
      (params[:cancellation] || ActionController::Parameters.new).permit(:override_reason)
    end
  end
end
