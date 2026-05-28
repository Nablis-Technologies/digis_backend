module Organizations
  class MembershipPolicy < Core::ApplicationPolicy
    def index?
      return true if user.super_admin?
      org_id = record.organization_id || record.organization&.id
      return false unless org_id
      Organizations::Membership.exists?(user_id: user.id, organization_id: org_id, role: :owner)
    end

    def show?
      record.organization&.owner == user || user.super_admin?
    end

    def create?
      record.organization&.owner == user || user.super_admin?
    end

    def update?
      record.organization&.owner == user || user.super_admin?
    end

    def destroy?
      record.organization&.owner == user || user.super_admin?
    end

    VISIBILITY = {
      show: {
        default: nil,
        admin: nil
      }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user.super_admin?
        org_ids = Organizations::Organization.joins(:memberships)
                     .where(organizations_memberships: { user_id: user.id, role: :owner })
                     .select(:id)
        scope.where(organization_id: org_ids)
      end
    end
  end
end
