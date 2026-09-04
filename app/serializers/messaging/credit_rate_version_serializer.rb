# frozen_string_literal: true

module Messaging
  # Exposes the versioned commercial rate used for quoting, without lifecycle
  # actor records or idempotency digests that are not part of the API contract.
  class CreditRateVersionSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :organization_id, :channel, :version, :currency, :unit_price_minor,
      :provider_cost_minor, :country_code, :volume_tiers, :effective_from, :effective_until,
      :status, :created_at
  end
end
