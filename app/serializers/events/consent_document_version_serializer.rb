# frozen_string_literal: true

module Events
  class ConsentDocumentVersionSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :consent_document_version

    attributes :id, :consent_document_id, :version, :title, :body,
               :content_sha256, :required, :acceptance_scope, :status,
               :published_by_id, :published_at, :created_by_id,
               :created_at, :updated_at
  end
end
