# frozen_string_literal: true

module Ticketing
  # Controls visibility of scanner lifecycle responses without exposing token
  # digests or other authentication material.
  class ScannerDevicePolicy < Core::ApplicationPolicy
    SAFE_FIELDS = %i[
      id organization_id device_identifier name status last_seen_at revoked_at created_at updated_at
    ].freeze

    def show?
      Events::AuthorizationResolver.organization_admin?(user, record.organization)
    end

    alias rotate_token? show?
    alias revoke? show?

    VISIBILITY = {
      rotate_token: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      revoke: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } }
    }.freeze
  end
end
