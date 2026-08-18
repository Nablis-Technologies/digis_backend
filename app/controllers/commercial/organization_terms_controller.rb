# frozen_string_literal: true

module Commercial
  # Organizer read endpoint for applicable current/scheduled terms and safe
  # acceptance/event-exception evidence. It has no generic Commercial writes.
  class OrganizationTermsController < Commercial::ApplicationController
    def show
      organization = ::Organizations::Organization.find(params[:organization_id])
      result = ::Commercial::Queries::OrganizationTerms.call(organization:)
      return render_service_result(result) if result.failure?

      terms = result.value
      authorize terms, :show?, policy_class: ::Commercial::OrganizationTermsPolicy
      serialized_terms = ActiveModelSerializers::SerializableResource.new(
        terms, serializer: ::Commercial::OrganizationTermsSerializer
      ).as_json
      render_success(
        data: serialized_terms
      )
    end
  end
end
