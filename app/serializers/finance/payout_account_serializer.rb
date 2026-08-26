# frozen_string_literal: true

module Finance
  # Safe destination projection. Account numbers, holder names, ciphertext,
  # digests, and provider credentials never cross this boundary.
  class PayoutAccountSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :organization_id, :type, :provider, :bank_code, :account_label,
               :status, :verification_source, :is_default, :verified_at,
               :last_used_at, :created_at, :updated_at
  end
end
