module Events
  class ArtistPolicy < Core::ApplicationPolicy
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

    def follow?
      true
    end

    def unfollow?
      true
    end

    def followers?
      true
    end

    VISIBILITY = {
      index: {
        default: { fields: %i[id name slug description genres verified active], include: [] },
        admin: { include: [] }
      },
      show: {
        default: { fields: %i[id name slug description image_url genres social_links verified active followers_count], include: [] },
        admin: { include: [] }
      }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.active
      end
    end
  end
end
