# frozen_string_literal: true

module Admin
  module Messaging
    # Baseline template metadata projection. Version bodies are managed by the
    # template authoring workflow and are not mixed into this definition row.
    class CampaignTemplateSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :organization_id, :created_by_id, :name, :channel, :status,
        :metadata, :created_at, :updated_at
    end
  end
end
