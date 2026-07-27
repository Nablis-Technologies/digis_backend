# frozen_string_literal: true

module Legal
  class LegalDocumentSerializer < ActiveModel::Serializer
    attributes :id, :document_type, :internal_name, :jurisdiction_code, :locale,
               :active, :created_by_id, :created_at, :updated_at

    has_many :versions, serializer: Legal::LegalDocumentVersionSerializer
  end
end
