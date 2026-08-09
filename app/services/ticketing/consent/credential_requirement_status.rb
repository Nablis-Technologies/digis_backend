# frozen_string_literal: true

module Ticketing
  module Consent
    # Small credential-boundary projection. It reports only required consent
    # completion; no credential or revocation model is invented here.
    class CredentialRequirementStatus < Core::BaseService
      Projection = Data.define(:status, :pending_requirements)

      def initialize(registration:)
        @registration = registration
      end

      def call
        pending = RegistrationConsentRequirement
          .where(registration_id: registration.id, required: true, status: "pending")
          .order(:package_unit_number, :admission_position, :id)
          .to_a
        success(Projection.new(status: pending.empty? ? "complete" : "pending", pending_requirements: pending))
      end

      private

      attr_reader :registration
    end
  end
end
