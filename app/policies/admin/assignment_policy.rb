# frozen_string_literal: true

module Admin
  # Grants and negotiated assignments share a resource but use separate grant
  # authorization, preventing ordinary drafters from issuing platform money.
  class AssignmentPolicy < Core::ApplicationPolicy
    def index? = commercial_permission?(:view)
    def show? = commercial_permission?(:view)
    def create? = commercial_permission?(:draft) && grant_authorized?
    def submit? = commercial_permission?(:submit) && grant_authorized?
    def approve? = commercial_permission?(:approve) && grant_authorized?
    def reject? = commercial_permission?(:approve) && grant_authorized?
    def activate? = commercial_permission?(:activate) && grant_authorized?
    def terminate? = commercial_permission?(:terminate)

    VISIBILITY = {
      index: { admin: { fields: :all, include: :all }, default: { fields: :all, include: [] } },
      show: { admin: { fields: :all, include: :all }, default: { fields: :all, include: [] } },
      create: { admin: { fields: :all, include: :all }, default: { fields: :all, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.super_admin? || user&.has_permission?("commercial.view")

        scope.none
      end
    end

    private

    def grant_authorized?
      !record.respond_to?(:platform_grant?) || !record.platform_grant? || commercial_permission?(:grant)
    end

    def commercial_permission?(action)
      user&.super_admin? || user&.has_permission?("commercial.#{action}")
    end
  end
end
