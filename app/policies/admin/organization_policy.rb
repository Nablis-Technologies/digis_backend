module Admin
  class OrganizationPolicy < Core::ApplicationPolicy
    def index? = allowed?(:index)
    def show? = allowed?(:show)
    def create? = allowed?(:create)
    def update? = allowed?(:update)
    def destroy? = allowed?(:destroy)

    def transfer_ownership?
      allowed?(:transfer_ownership)
    end

    # Verification documents are never returned as blob URLs; platform admins
    # receive them only through the authenticated short-lived download action.
    def download_documents?
      user&.super_admin? || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
    end

    VISIBILITY = {
      index: { admin: { include: :all, fields: :all } },
      show: { admin: { include: :all, fields: :all } },
      create: { admin: { include: :all, fields: :all } },
      update: { admin: { include: :all, fields: :all } }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?
        return scope.all if user.has_permission?("organization.index") || user.has_permission?("organization.show")

        scope.none
      end

      private

      def index_permission_code
        "organization.index"
      end
    end
  end
end
