# frozen_string_literal: true

module Events
  class ConsentDocumentSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :consent_document

    attributes :id, :name, :type, :active, :event_id,
               :created_by_id, :created_at, :updated_at

    has_many :versions, serializer: Events::ConsentDocumentVersionSerializer
  end
end
