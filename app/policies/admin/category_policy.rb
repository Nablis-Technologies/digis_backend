module Admin
  class CategoryPolicy < Events::CategoryPolicy
    def index?
      allowed?(:index)
    end

    def show?
      allowed?(:show)
    end
  end
end
