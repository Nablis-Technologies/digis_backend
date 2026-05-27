module Admin
  class RolePolicy < Core::ApplicationPolicy
    def index?
      allowed?(:index)
    end

    def show?
      allowed?(:show)
    end

    def create?
      allowed?(:create)
    end

    def update?
      allowed?(:update)
    end

    def destroy?
      allowed?(:destroy)
    end

    VISIBILITY = {
      index: {
        admin: { fields: %i[id code name description active], include: %i[permissions] },
        default: { fields: %i[id code name active], include: %i[permissions] }
      },
      show: {
        admin: { fields: %i[id code name description active created_at updated_at], include: %i[permissions] },
        default: { fields: %i[id code name active], include: %i[permissions] }
      },
      create: {
        admin: { fields: %i[id code name active], include: %i[permissions] },
        default: { fields: %i[id code name active], include: %i[permissions] }
      },
      update: {
        admin: { fields: %i[id code name active], include: %i[permissions] },
        default: { fields: %i[id code name active], include: %i[permissions] }
      }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?
        return scope.all if user.has_permission?("role.index")

        scope.none
      end

      private

      def index_permission_code
        "role.index"
      end
    end
  end
end
