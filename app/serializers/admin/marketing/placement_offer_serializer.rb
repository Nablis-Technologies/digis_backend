# frozen_string_literal: true

module Admin
  module Marketing
    # Administrative projection for offer configuration; idempotency and
    # request digests are deliberately excluded from the API response.
    class PlacementOfferSerializer < ActiveModel::Serializer
      include Core::AttributeVisibilitySerializer

      attributes :id, :code, :version, :surface, :daily_rate_minor, :currency,
        :minimum_duration_seconds, :maximum_duration_seconds, :terms_version, :status,
        :starts_at, :ends_at, :created_by_id, :activated_by_id, :retired_by_id,
        :activated_at, :retired_at, :created_at, :updated_at
    end
  end
end
