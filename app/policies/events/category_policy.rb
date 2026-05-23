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
        default: %i[id name description slug metadata active],
        admin: nil
      }
    }.freeze

    def visible_attributes_for(record:, action:)
      config = VISIBILITY[action.to_sym]
      return nil unless config

      if config.key?(user_role_key)
        config[user_role_key]
      else
        config[:default]
      end
    end

    private

    def user_role_key
      return :admin if user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN")
      :default
    end

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN")

        scope.active
      end
    end
  end
end
