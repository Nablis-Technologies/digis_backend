# frozen_string_literal: true

module Ticketing
  # Claim responses may be viewed by the package owner or authenticated
  # recipient; token and contact digests remain excluded by the serializer.
  class CredentialClaimPolicy < Core::ApplicationPolicy
    FIELDS = %i[id credential_id invited_user_id claimed_by_user_id status expires_at accepted_at created_at updated_at].freeze

    # Claim access is enforced by the invite/accept commands; this policy
    # provides serializer visibility for their already-authorized response.
    def show? = true

    VISIBILITY = {
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      create: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } },
      accept: { default: { fields: FIELDS, include: [] }, admin: { fields: :all, include: :all } }
    }.freeze
  end
end
