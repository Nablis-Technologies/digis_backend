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

    def visible_attributes_for(record:, action:)
      return nil unless action.to_sym == :show
      return nil if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
      %i[id name description slug metadata active]
    end

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN")

        scope.active
      end
    end
  end
end
