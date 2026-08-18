# frozen_string_literal: true

module Admin
  # Authorizes platform fee-schedule inspection and draft authoring. Lifecycle
  # changes belong to the version policy, keeping schedule identity stable.
  class FeeSchedulePolicy < Core::ApplicationPolicy
    def index? = commercial_permission?(:view)
    def show? = commercial_permission?(:view)
    def create? = commercial_permission?(:draft)
    def update? = commercial_permission?(:draft)
    def destroy? = false

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
