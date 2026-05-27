module Admin
  class UserPolicy < Core::ApplicationPolicy
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

    def deactivate?
      allowed?(:deactivate)
    end

    def reactivate?
      return false if record.deactivation_fraud? && !user.super_admin?
      allowed?(:reactivate)
    end

    def destroy?
      allowed?(:destroy)
    end

    VISIBILITY = {
      index: {
        admin: { fields: %i[id email phone verified_at deactivated_at deactivated_reason], include: %i[roles] },
        default: { fields: %i[id email phone verified_at deactivated_at], include: %i[roles] }
      },
      show: {
        admin: { fields: %i[id email phone verified_at deactivated_at deactivated_reason created_at updated_at], include: %i[roles] },
        default: { fields: %i[id email phone verified_at deactivated_at created_at updated_at], include: %i[roles] }
      },
      create: {
        admin: { fields: %i[id email phone verified_at], include: %i[roles] },
        default: { fields: %i[id email phone verified_at], include: %i[roles] }
      },
      update: {
        admin: { fields: %i[id email phone verified_at], include: %i[roles] },
        default: { fields: %i[id email phone verified_at], include: %i[roles] }
      }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?
        return scope.all if user.has_permission?("user.index") || user.has_permission?("user.show")

        scope.none
      end

      private

      def index_permission_code
        "user.index"
      end
    end
  end
end
