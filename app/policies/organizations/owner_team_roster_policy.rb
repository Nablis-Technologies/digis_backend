# frozen_string_literal: true

module Organizations
  class OwnerTeamRosterPolicy < Core::ApplicationPolicy
    def show?
      return true if user&.super_admin?
      return false unless user && record

      Membership.active.where(user_id: user.id, organization_id: record.id, role: %w[owner admin]).exists?
    end

    VISIBILITY = {
      show: { default: { fields: %i[memberships invitations], include: [] } }
    }
  end
end
