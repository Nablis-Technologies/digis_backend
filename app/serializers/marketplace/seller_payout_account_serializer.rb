# frozen_string_literal: true

module Marketplace
  # Safe tokenized payout destination projection. Encrypted display values
  # and provider account tokens never cross the API boundary.
  class SellerPayoutAccountSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :user_id, :type, :provider, :status, :verified_at, :last_used_at,
               :created_at, :updated_at
  end
end
