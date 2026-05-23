module Events
  class CategoryPolicy < Core::ApplicationPolicy
    def index?
      true
    end

    def show?
      true
    end

    def create?
      user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
    end

    def update?
      user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
    end

    def destroy?
      user.has_role?("SUPER_ADMIN")
    end

    VISIBILITY = {
      show: {
        default: { fields: %i[id name description slug metadata active], include: [] },
        admin: {
          include: [:audit_logs],
          association_fields: {
            audit_logs: { fields: %i[id action created_at] }
          }
        }
      }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN")

        scope.active
      end
    end
  end
end
