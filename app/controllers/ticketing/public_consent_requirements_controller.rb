# frozen_string_literal: true

module Ticketing
  # Public registration discovery surface. It deliberately exposes only exact
  # current consent versions, never organizer controls or acceptance evidence.
  class PublicConsentRequirementsController < Events::ApplicationController
    skip_before_action :authenticate_user
    skip_authorization

    def index
      event = Events::Event.publicly_visible.find_by!(slug: params[:event_slug])
      ticket_type = Catalog::EventProduct.active.joins(:ticket_type).find_by!(
        event:,
        ticketing_ticket_types: { id: params[:ticket_type_id] }
      ).ticket_type
      result = Ticketing::Consent::ApplicableRequirements.call(event:, ticket_type:)

      render_success(
        data: result.value,
        serializer_options: { serializer: Ticketing::PublicConsentRequirementSerializer }
      )
    end
  end
end
