# frozen_string_literal: true

module Admin
  module Messaging
    # Safe quota policy projection; request and idempotency digests are never
    # response fields even though administrators can update the policy.
    class CampaignVolumePolicySerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :organization_id, :channel, :timezone, :daily_limit, :monthly_limit,
        :active, :updated_by_id, :created_at, :updated_at
    end
  end
end
