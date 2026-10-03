# frozen_string_literal: true

module Ticketing
  # Thin package-transfer endpoints. Pending state is append-only and only the
  # recipient acceptance command changes the ticket owner or generation.
  class TransfersController < Ticketing::ApplicationController
    include Core::CommandResponse

    skip_authorization only: %i[accept decline cancel]

    before_action :ensure_idempotency_key_present
    before_action :load_ticket, only: :create

    def create
      authorize @ticket, :transfer?, policy_class: Ticketing::TicketPolicy
      result = Ticketing::Transfers::Initiate.call(
        ticket: @ticket,
        actor: current_user,
        phone: params.require(:phone),
        reason: params[:reason],
        expires_at: params[:expires_at],
        idempotency_key:
      )
      return render_service_result(result, success_status: :created) if result.failure?

      render_success(
        data: { transfer: result.value.transfer, token: result.value.token },
        status: :created,
        serializer_options: {
          transfer: { serializer: Ticketing::TicketTransferSerializer }
        }
      )
    end

    def accept
      result = Ticketing::Transfers::Accept.call(
        transfer_id: params.require(:id), token: params[:token], actor: current_user
      )
      return render_service_result(result) if result.failure?

      render_success(
        data: result.value,
        serializer_options: { serializer: Ticketing::TicketTransferSerializer }
      )
    end

    def decline
      transfer = Ticketing::TicketTransfer.find(params.require(:id))
      result = Ticketing::Transfers::Decline.call(
        transfer:,
        actor: current_user,
        idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: { serializer: Ticketing::TicketTransferSerializer }
      )
    end

    def cancel
      transfer = Ticketing::TicketTransfer.find(params.require(:id))
      result = Ticketing::Transfers::Cancel.call(
        transfer:,
        actor: current_user,
        idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: { serializer: Ticketing::TicketTransferSerializer }
      )
    end

    private

    def load_ticket
      @ticket = Ticketing::Ticket.find(params[:ticket_id])
    end
  end
end
