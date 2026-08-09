# frozen_string_literal: true

module Ticketing
  # Exposes queue and offer commands without allowing controllers to edit
  # registration state directly.
  class WaitlistOffersController < Ticketing::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present

    def offer_next
      ticket_type = Ticketing::TicketType
        .includes(event_product: :event)
        .find(params[:id])
      authorize Ticketing::Registration.new(event: ticket_type.event), :offer_next?
      result = Ticketing::Waitlist::OfferNext.call(
        ticket_type:,
        selected_event_date_id: params[:selected_event_date_id],
        idempotency_key:
      )
      render_result(result)
    end

    def enqueue
      registration = load_registration
      authorize registration, :enqueue_waitlist?
      result = Ticketing::Waitlist::Enqueue.call(
        registration:,
        actor: current_user,
        idempotency_key:
      )
      render_result(result)
    end

    def accept
      registration = load_registration
      authorize registration, :accept_waitlist_offer?
      result = Ticketing::Waitlist::AcceptOffer.call(
        registration:,
        actor: current_user,
        idempotency_key:
      )
      render_result(result)
    end

    private

    def load_registration
      Ticketing::Registration
        .includes(:event, :user, :consent_requirements, ticket_type: :event_product)
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
