# frozen_string_literal: true

module Admin
  class DataRetentionHoldPolicy < Core::ApplicationPolicy
    def index? = platform_admin?
    def show? = platform_admin?
    def create? = platform_admin?
    def release? = platform_admin?
    def update? = false
    def destroy? = false

    VISIBILITY = {
      index: { admin: { fields: :all, include: [] } },
      show: { admin: { fields: :all, include: [] } },
      create: { admin: { fields: :all, include: [] } },
      release: { admin: { fields: :all, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        platform_admin? ? scope : scope.none
      end

      private

      def platform_admin?
        user&.has_role?("SUPER_ADMIN") || user&.has_role?("CORE_ADMIN")
      end
    end

    private

    def platform_admin?
      user&.has_role?("SUPER_ADMIN") || user&.has_role?("CORE_ADMIN")
    end
  end
end
