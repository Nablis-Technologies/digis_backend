# frozen_string_literal: true

module Admin
  # Authorization for the platform-administration events surface. Mirrors
  # Admin::OrganizationPolicy: super admins bypass, others need the matching
  # RBAC permission (event.index, event.update, event.publish, ...).
  class EventPolicy < Core::ApplicationPolicy
    def index? = allowed?(:index)
    def show? = allowed?(:show)
    def create? = allowed?(:create)
    def update? = allowed?(:update)
    def destroy? = allowed?(:destroy)

    def publish? = allowed?(:publish)
    def unpublish? = allowed?(:unpublish)

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
        return scope.all if user.has_permission?("event.index") || user.has_permission?("event.show")

        scope.none
      end
    end
  end
end
