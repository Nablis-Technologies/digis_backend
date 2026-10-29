# frozen_string_literal: true

module Messaging
  class CampaignTemplateSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :organization_id, :created_by_id, :name, :channel, :status, :created_at, :updated_at
  end
end
