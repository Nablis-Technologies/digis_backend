module Organizations
  class OrganizationPolicy < Core::ApplicationPolicy
    def index?
      true
    end

    def show?
      record.owner == user || user.super_admin?
    end

    def create?
      true
    end

    def update?
      record.owner == user || user.super_admin?
    end

    def destroy?
      record.owner == user || user.super_admin?
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
        scope.joins(:memberships)
             .where(organizations_memberships: { user_id: user.id, role: 0 })
      end
    end
  end
end
