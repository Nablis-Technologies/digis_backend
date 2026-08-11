# frozen_string_literal: true

module Ticketing
  # Appends a signer-owned withdrawal and returns only completion state and
  # affected coordinates; no withdrawal reason or evidence is serialized.
  class RegistrationConsentWithdrawalsController < Ticketing::ApplicationController
    before_action :ensure_idempotency_key_present, only: :create

    def create
      consent = Ticketing::RegistrationConsent
        .includes(registration: :event, registration_consent_requirement: :registration)
        .find(params[:registration_consent_id])
      @registration = consent.registration
      authorize consent, :withdraw?

      result = Ticketing::Consent::Withdraw.call(
        consent:,
        actor: current_user,
        idempotency_key:,
        reason_code: params[:reason_code]
      )
      return render_service_result(result) if result.failure?

      render_success(data: projection_data(result.value))
    end

    private

    def projection_data(projection)
      {
        status: projection.status,
        pending_coordinates: visible_pending_requirements(projection.pending_requirements).map do |requirement|
          { package_unit_number: requirement.package_unit_number, admission_position: requirement.admission_position }
        end
      }
    end

    def visible_pending_requirements(requirements)
      return [] if requirements.empty?

      visible_ids = Ticketing::RegistrationConsentPolicy::Scope
        .new(current_user, Ticketing::RegistrationConsentRequirement.where(id: requirements.map(&:id)))
        .resolve
        .where(acceptance_scope: "admission_slot")
        .pluck(:id)
      requirements.select { |requirement| visible_ids.include?(requirement.id) }
    end
  end
end
