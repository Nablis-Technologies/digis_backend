# frozen_string_literal: true

module Admin
  module Messaging
    # Operational campaign projection with aggregate audience progress only.
    # Message bodies, contact material, provider identifiers, and ledger rows
    # stay outside the API response even for platform administrators.
    class CampaignSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :organization_id, :created_by_id, :event_id, :name, :channel, :status,
        :timezone, :launch_version, :send_at, :launched_at, :completed_at, :canceled_at,
        :variables, :quoted_quantity, :quoted_unit_price_minor, :quoted_rate_version_id, :quoted_at, :quote_expires_at,
        :audience_status, :audience_total_count, :audience_eligible_quantity,
        :created_at, :updated_at

      def audience_status = object.audience_snapshot&.status

      def audience_total_count = object.audience_snapshot&.total_count

      def audience_eligible_quantity = object.audience_snapshot&.eligible_quantity
    end
  end
end
