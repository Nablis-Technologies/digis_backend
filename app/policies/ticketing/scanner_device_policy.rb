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

    alias index? show?
    alias rotate_token? show?
    alias revoke? show?

    VISIBILITY = {
      index: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      rotate_token: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      revoke: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")

        organization_ids = Organizations::Membership.where(
          user:, status: "active", role: %w[owner admin]
        ).select(:organization_id)
        scope.where(organization_id: organization_ids)
      end
    end
  end
end
