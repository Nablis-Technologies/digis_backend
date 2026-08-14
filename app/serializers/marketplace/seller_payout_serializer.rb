# frozen_string_literal: true

module Marketplace
  # Seller/admin payout lifecycle projection without provider references,
  # idempotency material, or raw failure diagnostics.
  class SellerPayoutSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :seller_user_id, :seller_payout_account_id, :provider, :amount_minor,
               :currency, :status, :requested_at, :processed_at, :created_at, :updated_at
  end
end
