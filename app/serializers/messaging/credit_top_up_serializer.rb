# frozen_string_literal: true

module Messaging
  # Exposes a purchase intent and its provider reference after authorization;
  # payment credentials and raw provider responses are never serialized.
  class CreditTopUpSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :organization_id, :credit_account_id, :rate_version_id, :channel,
      :quantity, :currency, :amount_minor, :price_digest, :status, :provider_reference,
      :created_at, :updated_at
  end
end
