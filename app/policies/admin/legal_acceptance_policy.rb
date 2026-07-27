# frozen_string_literal: true

module Admin
  class LegalAcceptancePolicy < Core::ApplicationPolicy
    def index? = user.super_admin?
    def show? = user.super_admin?
    def create? = false # only Legal::RecordAcceptance command writes
    def destroy? = false

    VISIBILITY = {
      index:  { default: { fields: :all, include: :all }, admin: { fields: :all, include: :all } },
      show:   { default: { fields: :all, include: :all }, admin: { fields: :all, include: :all } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve = user.super_admin? ? scope : scope.none
    end
  end
end
