module Admin
  class VenuePolicy < Events::VenuePolicy
    def index?
      allowed?(:index)
    end

    def show?
      allowed?(:show)
    end
  end
end
