module Admin
  class UserRolePolicy < Core::ApplicationPolicy
    def index?
      allowed?(:index)
    end

    def create?
      return false unless allowed?(:create)
      return false unless user.super_admin? || assignable_role?

      true
    end

    def destroy?
      return false unless allowed?(:destroy)
      return false unless user.super_admin? || assignable_role?

      true
    end

    private

    def assignable_role?
      role_code = record.role&.code
      return true unless role_code

      %w[USER SUPPORT].include?(role_code)
    end

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?
        return scope.all if user.has_permission?("user_role.index")

        scope.none
      end

      private

      def index_permission_code
        "user_role.index"
      end
    end
  end
end
