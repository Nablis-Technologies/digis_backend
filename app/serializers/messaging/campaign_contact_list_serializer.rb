# frozen_string_literal: true

module Messaging
  class CampaignContactListSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :organization_id, :created_by_id, :name, :status, :version, :created_at, :updated_at
  end
end
