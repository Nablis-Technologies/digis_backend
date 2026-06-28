module Admin
  class PermissionPolicy < Core::ApplicationPolicy
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
        admin: { fields: %i[id code resource action namespace description active], include: :all },
        default: { fields: %i[id code resource action namespace], include: :all }
      },
      show: {
        admin: { fields: %i[id code resource action namespace description active created_at updated_at], include: :all },
        default: { fields: %i[id code resource action namespace], include: :all }
      },
      create: {
        admin: { fields: %i[id code resource action namespace], include: :all },
        default: { fields: %i[id code resource action namespace], include: :all }
      },
      update: {
        admin: { fields: %i[id code resource action namespace], include: :all },
        default: { fields: %i[id code resource action namespace], include: :all }
      }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?
        return scope.all if user.has_permission?("permission.index")

        scope.none
      end

      private

      def index_permission_code
        "permission.index"
      end
    end
  end
end
