module Events
  class VenuePolicy < Core::ApplicationPolicy
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

    VISIBILITY = {
      index: {
        default: { fields: %i[id name slug description address city country capacity verified active], include: [] },
        admin: { include: [], fields: :all }
      },
      show: {
        default: { fields: %i[id name slug description address city country latitude longitude capacity amenities social_links contact_phone contact_email website_url verified active followers_count], include: [] },
        admin: { include: [], fields: :all }
      }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        scope.active
      end
    end
  end
end
