# frozen_string_literal: true

module Marketplace
  # Safe payout destination projection. Encrypted beneficiary values and
  # account digests never cross the API boundary.
  class SellerPayoutAccountSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :user_id, :type, :provider, :bank_slug, :account_label, :status,
               :verification_source, :is_default, :verified_at, :last_used_at, :created_at, :updated_at
  end
end
