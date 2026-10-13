# frozen_string_literal: true

module Marketing
  class FeaturedPlacementSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :event_id, :status, :surface, :starts_at, :ends_at, :duration_seconds,
      :offer_code, :offer_version, :daily_rate_minor, :amount_minor, :currency, :terms_version,
      :created_at, :updated_at
  end
end
