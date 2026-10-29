# frozen_string_literal: true

module Messaging
  class CampaignContactListSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :organization_id, :created_by_id, :name, :status, :version,
               :entries_count, :created_at, :updated_at

    def entries_count
      return instance_options[:active_entry_counts].fetch(object.id, 0) if instance_options[:active_entry_counts]

      object.entries.where(status: "active").count
    end
  end
end
