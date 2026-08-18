# frozen_string_literal: true

module Ticketing
  # Thin organizer/platform endpoints for the suspension lifecycle. All
  # projection, financial-boundary, locking, audit, and outbox rules live in
  # the three suspension commands.
  class SuspensionsController < Ticketing::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present
    before_action :load_ticket
    before_action :load_suspension, only: %i[restore resolve]

    def create
      authorize @ticket, :suspend?, policy_class: Ticketing::TicketPolicy
      result = Ticketing::Suspensions::Open.call(
        ticket: @ticket,
        actor: current_user,
        reason_code: suspension_params.require(:reason_code),
        review_deadline_at: suspension_params[:review_deadline_at],
        internal_note: suspension_params[:internal_note],
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: Ticketing::TicketSuspensionSerializer }
      )
    end

    def restore
      authorize @ticket, :restore_suspension?, policy_class: Ticketing::TicketPolicy
      result = Ticketing::Suspensions::Restore.call(
        suspension: @suspension,
        actor: current_user,
        resolution_reason: params.require(:resolution_reason),
        idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: { serializer: Ticketing::TicketSuspensionSerializer }
      )
    end

    def resolve
      authorize @ticket, :resolve_suspension?, policy_class: Ticketing::TicketPolicy
      result = Ticketing::Suspensions::Resolve.call(
        suspension: @suspension,
        actor: current_user,
        resolution: params.require(:resolution),
        resolution_reason: params.require(:resolution_reason),
        idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: { serializer: Ticketing::TicketSuspensionSerializer }
      )
    end

    private

    def load_ticket
      @ticket = Ticketing::Ticket.includes(:event, :revocation).find(params[:ticket_id])
    end

    def load_suspension
      @suspension = @ticket.ticket_suspensions.order(created_at: :desc).first
      return if @suspension

      render_error(
        :"ticketing.suspensions.errors.suspension_not_found",
        status: :not_found,
        code: "suspension_not_found"
      )
    end

    def suspension_params
      params.permit(:reason_code, :review_deadline_at, :internal_note)
    end
  end
end
