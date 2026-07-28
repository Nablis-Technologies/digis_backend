# frozen_string_literal: true

module Catalog
  class ProductPricePolicy < Core::ApplicationPolicy
    def index? = admin?
    def show?  = admin?
    def create? = admin?

    VISIBILITY = {
      index: {
        default: { fields: [], include: [] },
        admin: { include: :all, fields: :all }
      },
      show: {
        default: { fields: [], include: [] },
        admin: { include: :all, fields: :all }
      },
      create: {
        default: { fields: [], include: [] },
        admin: { include: :all, fields: :all }
      }
    }

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user_admin?

        scope.none
      end

      private

      def user_admin?
        user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
      end
    end

    private

    def admin?
      user_role_key == :admin
    end
  end
end
