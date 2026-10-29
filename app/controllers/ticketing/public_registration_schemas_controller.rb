# frozen_string_literal: true

module Ticketing
  # Anonymous schema discovery for a published event and active ticket type.
  # Only current published form versions and attendee-safe consent metadata are
  # returned; registration answers and organizer publication controls are not.
  class PublicRegistrationSchemasController < Ticketing::ApplicationController
    skip_before_action :authenticate_user
    skip_authorization

    def show
      event = Events::Event.publicly_visible.find_by(slug: params[:event_slug])
      return not_found unless event

      product = Catalog::EventProduct.active
        .includes(:ticket_type)
        .find_by(event:, ticketing_ticket_types: { id: params[:ticket_type_id] })
      return not_found unless product&.ticket_type

      schema = Ticketing::Forms::ApplicableSchema.call(event:, ticket_type: product.ticket_type)
      return render_error(schema.error.message, status: schema.error.status_code, code: schema.error.code) if schema.failure?

      consent = Ticketing::Consent::ApplicableRequirements.call(event:, ticket_type: product.ticket_type)
      render_success(
        data: {
          event_id: event.id,
          ticket_type_id: product.ticket_type.id,
          forms: schema.value.map { |version| Ticketing::Public::RegistrationSchemaSerializer.new(version).attributes },
          consent_requirements: consent.value.map { |version| Ticketing::PublicConsentRequirementSerializer.new(version).attributes }
        }
      )
    end

    private

    def not_found
      render_error(I18n.t("errors.not_found", model: "registration schema"), status: :not_found)
    end
  end
end
