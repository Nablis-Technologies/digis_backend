module Admin
  class ArtistPolicy < Events::ArtistPolicy
    def index?
      allowed?(:index)
    end

    def show?
      allowed?(:show)
    end
  end
end
