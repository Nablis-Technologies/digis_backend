# frozen_string_literal: true

module Messaging
  # Organizer-safe campaign projection; payloads, recipients, and provider
  # identities remain behind dedicated operational surfaces.
  class CampaignSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :organization_id, :created_by_id, :event_id, :name, :channel, :status,
      :timezone, :launch_version, :send_at, :launched_at, :completed_at, :canceled_at, :variables,
      :quoted_quantity, :quoted_unit_price_minor, :quoted_rate_version_id, :quoted_at, :quote_expires_at
  end
end
