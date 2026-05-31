module Core
  class FollowPolicy < Core::ApplicationPolicy
    def create?
      user.present?
    end

    def destroy?
      user.present?
    end

    def following?
      record == user
    end

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.all
      end
    end
  end
end
