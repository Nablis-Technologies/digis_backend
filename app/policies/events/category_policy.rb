module Events
  class CategoryPolicy < Core::ApplicationPolicy
    def index?
      true
    end

    def show?
      true
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
        default: { fields: %i[id name slug], include: [] },
        admin: { include: [], fields: :all }
      },
      show: {
        default: { fields: %i[id name description slug metadata active], include: [] },
        admin: { include: [ :audit_logs ], fields: :all }
      }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
        scope.active
      end
    end
  end
end
