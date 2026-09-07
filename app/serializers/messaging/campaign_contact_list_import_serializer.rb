# frozen_string_literal: true

module Messaging
  class CampaignContactListImportSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :campaign_contact_list_id, :created_by_id, :status, :filename,
      :total_rows, :accepted_rows, :duplicate_rows, :invalid_rows, :suppressed_rows,
      :missing_channel_rows, :error_detail, :started_at, :completed_at, :created_at, :updated_at
  end
end
