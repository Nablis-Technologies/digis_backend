# frozen_string_literal: true

module Ticketing
  # Thin command endpoints for owner-controlled delegation transitions. All
  # generation, consent, locking, audit, and outbox behavior stays in services.
  class DelegationsController < Ticketing::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present
    before_action :load_ticket

    def create
      authorize @ticket, :delegate?, policy_class: Ticketing::TicketPolicy
      result = Ticketing::Delegations::Activate.call(
        ticket: @ticket,
        actor: current_user,
        assignments: params.require(:assignments).to_unsafe_h,
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: Ticketing::CredentialGenerationSerializer }
      )
    end

    def cancel
      authorize @ticket, :cancel_delegation?, policy_class: Ticketing::TicketPolicy
      result = Ticketing::Delegations::Cancel.call(
        ticket: @ticket,
        actor: current_user,
        idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: { serializer: Ticketing::CredentialGenerationSerializer }
      )
    end

    def reassign
      authorize @ticket, :reassign_slot?, policy_class: Ticketing::TicketPolicy
      result = Ticketing::Delegations::ReassignSlot.call(
        ticket: @ticket,
        actor: current_user,
        position: params.require(:position),
        replacement_user: replacement_params,
        idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: { serializer: Ticketing::CredentialGenerationSerializer }
      )
    end

    private

    def load_ticket
      @ticket = Ticketing::Ticket.find(params[:ticket_id])
    end

    def replacement_params
      params.permit(:replacement_user_id, :replacement_phone).to_h.deep_symbolize_keys.then do |attributes|
        attributes[:user_id] || attributes[:replacement_user_id] ||
          (attributes[:replacement_phone] ? { phone: attributes[:replacement_phone] } : nil)
      end
    end
  end
end
