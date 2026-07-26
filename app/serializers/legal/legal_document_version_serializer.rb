# frozen_string_literal: true

module Legal
  class LegalDocumentVersionSerializer < ActiveModel::Serializer
    attributes :id, :legal_document_id, :version, :title, :body, :content_sha256,
               :status, :commercial_policy_reference, :published_by_id,
               :published_at, :created_at, :updated_at
  end
end
