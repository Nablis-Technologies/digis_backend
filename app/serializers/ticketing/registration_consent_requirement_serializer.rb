# frozen_string_literal: true

module Ticketing
  # Public/staff-safe requirement projection. Document bodies, hashes, subject
  # IDs, acceptance rows, request IDs, and withdrawal reasons never leave here.
  class RegistrationConsentRequirementSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :registration_consent_requirement

    attributes :id, :registration_id, :consent_document_id, :document_version, :required,
               :acceptance_scope, :package_unit_number, :admission_position, :status,
               :required_reason, :required_at, :superseded_at, :subject_assigned

    def consent_document_id
      object.consent_document_version.consent_document_id
    end

    def document_version
      object.consent_document_version.version
    end

    def subject_assigned
      object.subject_user_id.present?
    end
  end
end
