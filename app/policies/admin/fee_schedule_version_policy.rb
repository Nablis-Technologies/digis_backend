# frozen_string_literal: true

module Admin
  # Separates definition authoring from lifecycle transitions and their
  # dedicated Commercial permissions.
  class FeeScheduleVersionPolicy < Core::ApplicationPolicy
    def index? = commercial_permission?(:view)
    def show? = commercial_permission?(:view)
    def create? = commercial_permission?(:draft)
    def update? = commercial_permission?(:draft)
    def simulate? = commercial_permission?(:simulate)
    def submit? = commercial_permission?(:submit)
    def approve? = commercial_permission?(:approve)
    def reject? = commercial_permission?(:approve)
    def schedule? = commercial_permission?(:activate)
    def activate? = commercial_permission?(:activate)
    def terminate? = commercial_permission?(:terminate)
    def deliver_notice? = commercial_permission?(:activate)

    VISIBILITY = {
      index: { admin: { fields: :all, include: :all }, default: { fields: :all, include: [] } },
      show: { admin: { fields: :all, include: :all }, default: { fields: :all, include: [] } },
      create: { admin: { fields: :all, include: :all }, default: { fields: :all, include: [] } },
      update: { admin: { fields: :all, include: :all }, default: { fields: :all, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.all if user&.super_admin? || user&.has_permission?("commercial.view")

        scope.none
      end
    end

    private

    def commercial_permission?(action)
      user&.super_admin? || user&.has_permission?("commercial.#{action}")
    end
  end
end
