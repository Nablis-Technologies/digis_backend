# frozen_string_literal: true

module Admin
  # Budget rows are operationally sensitive: even delegated Commercial admins
  # need the explicit budget_view permission to inspect or author capacity.
  class SubsidyBudgetPolicy < Core::ApplicationPolicy
    def index? = commercial_permission?(:budget_view)
    def show? = commercial_permission?(:budget_view)
    def create? = commercial_permission?(:budget_view)
    def update? = commercial_permission?(:budget_view)

    VISIBILITY = {
      index: { admin: { fields: :all, include: :all }, default: { fields: :all, include: [] } },
      show: { admin: { fields: :all, include: :all }, default: { fields: :all, include: [] } },
      create: { admin: { fields: :all, include: :all }, default: { fields: :all, include: [] } },
      update: { admin: { fields: :all, include: :all }, default: { fields: :all, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.super_admin? || user&.has_permission?("commercial.budget_view")

        scope.none
      end
    end

    private

    def commercial_permission?(action)
      user&.super_admin? || user&.has_permission?("commercial.#{action}")
    end
  end
end
