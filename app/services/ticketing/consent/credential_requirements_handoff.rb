# frozen_string_literal: true

module Ticketing
  module Consent
    # Publishes the credential boundary's minimum durable projection. Consent
    # contents, acceptance evidence, signers, and credential state never cross it.
    class CredentialRequirementsHandoff < Core::BaseService
      EVENT_TYPE = "ticketing.consent_credential_requirements_changed"

      def initialize(registration:, status:, affected_coordinates:, idempotency_key:)
        @registration = registration
        @status = status
        @affected_coordinates = affected_coordinates
        @idempotency_key = idempotency_key
      end

      def call
        Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: EVENT_TYPE,
          aggregate: registration,
          payload: {
            registration_id: registration.id,
            status: status,
            affected_coordinates: affected_coordinates.map do |requirement|
              { package_unit_number: requirement.package_unit_number, admission_position: requirement.admission_position }
            end
          },
          idempotency_key:
        )
      end

      private

      attr_reader :registration, :status, :affected_coordinates, :idempotency_key
    end
  end
end
