# frozen_string_literal: true

module Ticketing
  # Organizer endpoint for the normal zero-charge registration pipeline. The
  # command owns recipient resolution and all capacity/consent invariants.
  class ComplimentaryTicketsController < Ticketing::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present
    before_action :load_event

    def create
      ticket_type = Ticketing::TicketType
        .joins(:event_product)
        .includes(event_product: :event)
        .where(catalog_event_products: { event_id: @event.id })
        .find(params.require(:ticket_type_id))
      authorize Ticketing::Registration.new(event: @event), :complimentary?
      attributes = complimentary_params
      result = Ticketing::ComplimentaryIssuance::Issue.call(
        ticket_type:,
        actor: current_user,
        phone: attributes[:phone],
        package_quantity: attributes[:package_quantity],
        selected_event_date_id: attributes[:selected_event_date_id],
        reason: attributes[:reason],
        answers: attributes[:answers],
        consents: attributes[:consents],
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: Ticketing::RegistrationSerializer }
      )
    end

    private

    def load_event
      @event = Events::Event.find(params[:event_id])
    end

    def complimentary_params
      params.permit(
        :ticket_type_id, :phone, :package_quantity, :selected_event_date_id, :reason,
        answers: %i[question_key form_version_id package_unit_number admission_position value],
        consents: %i[consent_document_version_id request_uuid acceptance_method content_sha256 idempotency_key]
      ).to_h.deep_symbolize_keys
    end
  end
end
