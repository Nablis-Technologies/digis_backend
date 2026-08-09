# frozen_string_literal: true

module Ticketing
  # Exact-version consent review fields for anonymous registration discovery.
  class PublicConsentRequirementSerializer < ActiveModel::Serializer
    attributes :consent_document_version_id, :document_version, :title, :body,
               :content_sha256, :required, :acceptance_scope

    def consent_document_version_id = object.id
    def document_version = object.version
  end
end
