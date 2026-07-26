# frozen_string_literal: true

module Admin
  class LegalDocumentPolicy < Core::ApplicationPolicy
    def index? = user.super_admin?
    def show? = user.super_admin?
    def create? = user.super_admin?
    def update? = user.super_admin?
    def destroy? = false
    def publish? = user.super_admin?
    def activate?   = user.super_admin?
    def deactivate? = user.super_admin?

    VISIBILITY = {
      index:  { default: { fields: :all, include: :all }, admin: { fields: :all, include: :all } },
      show:   { default: { fields: :all, include: :all }, admin: { fields: :all, include: :all } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve = user.super_admin? ? scope : scope.none
    end
  end
end
