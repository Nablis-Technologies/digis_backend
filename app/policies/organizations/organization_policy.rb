module Organizations
  class OrganizationPolicy < Core::ApplicationPolicy
    def index?
      true
    end

    def show?
      true
    end

    def create?
      true
    end

    def update?
      record.owner == user || user&.super_admin?
    end

    def destroy?
      record.owner == user || user&.super_admin?
    end

    def follow?
      true
    end

    def unfollow?
      true
    end

    VISIBILITY = {
      index: {
        default: { fields: %i[id name slug description created_at], include: [] },
        admin: { include: [] }
      },
      show: {
        default: { fields: %i[id name slug description profile_url social_links followers_count created_at], include: [] },
        admin: { include: [] }
      }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.all
      end
    end
  end
end
