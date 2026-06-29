module Admin
  class MembershipPolicy < Core::ApplicationPolicy
    def index?
      return false unless user
      return true if user.super_admin?

      user.has_permission?("organization.show") || user.has_permission?("organization.manage_memberships")
    end

    def create?
      return false unless user
      return true if user.super_admin?

      user.has_permission?("organization.manage_memberships")
    end

    def update?
      create?
    end

    def destroy?
      create?
    end

    VISIBILITY = {
      index: { admin: { include: :all, fields: :all } },
      create: { admin: { include: :all, fields: :all } },
      update: { admin: { include: :all, fields: :all } },
      destroy: { admin: { include: :all, fields: :all } }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?
        return scope.all if user.has_permission?("organization.show") || user.has_permission?("organization.manage_memberships")

        scope.none
      end

      private

      def index_permission_code
        "organization.show"
      end
    end
  end
end
