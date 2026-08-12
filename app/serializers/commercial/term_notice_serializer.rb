# frozen_string_literal: true

module Commercial
  class TermNoticeSerializer < ActiveModel::Serializer
    attributes :id, :organization_id, :fee_schedule_version_id,
      :legal_document_version_id, :delivery_method, :status, :available_at,
      :delivered_at, :failed_at, :evidence_digest, :created_at, :updated_at
  end
end
