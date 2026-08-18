# frozen_string_literal: true

module Finance
  class ProviderReservePolicySerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :provider, :currency, :target_minor, :lock_version, :created_at, :updated_at
  end
end
