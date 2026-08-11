# frozen_string_literal: true

module Ticketing
  # Lists requirement projections and accepts one exact version without exposing
  # consent content, signer evidence, request UUIDs, or answer payloads.
  class RegistrationConsentsController < Ticketing::ApplicationController
    before_action :load_registration
    before_action :load_requirement, only: :accept
    before_action :ensure_idempotency_key_present, only: :accept

    def index
      all_requirements = @registration.consent_requirements
        .where.not(status: "superseded")
        .includes(registration: :event, consent_document_version: :consent_document)
        .order(:required_at, :id)
      requirements = policy_scope(
        all_requirements,
        policy_scope_class: Ticketing::RegistrationConsentPolicy::Scope
      )
      policy = Ticketing::RegistrationConsentPolicy
      target = requirements.find { |requirement| policy.new(current_user, requirement).index? }
      authorize(
        target || all_requirements.first || RegistrationConsentRequirement.new(registration: @registration),
        :index?,
        policy_class: policy
      )

      render_success(
        data: requirements,
        serializer_options: { serializer: Ticketing::RegistrationConsentRequirementSerializer }
      )
    end

    def accept
      authorize @requirement, :accept?, policy_class: Ticketing::RegistrationConsentPolicy
      result = Ticketing::Consent::Accept.call(
        requirement: @requirement,
        actor: current_user,
        request_uuid: params.require(:request_uuid),
        acceptance_method: params[:acceptance_method].presence || "otp",
        content_sha256: params[:content_sha256],
        idempotency_key:
      )
      return render_service_result(result) if result.failure?

      status = Ticketing::Consent::CredentialRequirementStatus.call(registration: @registration).value
      render_success(
        data: {
          requirement: @requirement.reload,
          status: status.status,
          pending_coordinates: visible_pending_requirements(status.pending_requirements).map do |requirement|
            { package_unit_number: requirement.package_unit_number, admission_position: requirement.admission_position }
          end
        },
        serializer_options: {
          requirement: { serializer: Ticketing::RegistrationConsentRequirementSerializer }
        }
      )
    end

    private

    def load_registration
      @registration = Ticketing::Registration.find(params[:registration_id])
    end

    def load_requirement
      @requirement = @registration.consent_requirements.find(params[:id])
    end

    def visible_pending_requirements(requirements)
      return [] if requirements.empty?

      visible_ids = policy_scope(
        RegistrationConsentRequirement.where(id: requirements.map(&:id)),
        policy_scope_class: Ticketing::RegistrationConsentPolicy::Scope
      ).where(acceptance_scope: "admission_slot").pluck(:id)
      requirements.select { |requirement| visible_ids.include?(requirement.id) }
    end
  end
end
