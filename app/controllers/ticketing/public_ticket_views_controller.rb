# frozen_string_literal: true

module Ticketing
  # Serves an expiring signed public ticket view for guest confirmation and
  # convenience links. It never treats the ticket ID or short-link slug as a
  # credential; the signed token and live generation are both revalidated.
  class PublicTicketViewsController < Ticketing::ApplicationController
    skip_before_action :authenticate_user
    skip_authorization

    def show
      response.set_header("Cache-Control", "no-store")
      token_result = Ticketing::GuestTicketViewToken.verify(params.require(:view_token))
      return render_service_result(token_result) if token_result.failure?
      return render_invalid_view unless token_result.value.ticket_id == params[:ticket_id].to_s

      ticket = Ticketing::Ticket.includes(
        :event,
        { current_credential_generation: :credentials },
        event_product: { product_accesses: { event_date: :venue } }
      ).find_by(id: params[:ticket_id])
      return render_invalid_view unless ticket && valid_ticket?(ticket, token_result.value)

      render_success(
        data: ticket,
        serializer_options: { serializer: Ticketing::PublicTicketViewSerializer }
      )
    rescue ActiveRecord::RecordNotFound, ActionController::ParameterMissing
      render_invalid_view
    end

    private

    def valid_ticket?(ticket, token)
      ticket.status == "active" && !ticket.event.cancelled? &&
        ticket.current_credential_generation&.status == "active" &&
        ticket.credential_version.to_i == token.credential_version.to_i &&
        ticket.current_credential_generation.version.to_i == token.credential_version.to_i
    end

    def render_invalid_view
      render_error(
        I18n.t("ticketing.guest_ticket.errors.invalid_view_token"),
        status: :not_found,
        code: "invalid_guest_ticket_view"
      )
    end
  end
end
