# frozen_string_literal: true

module Messaging
  class CreditAccountPolicy < Core::ApplicationPolicy
    FIELDS = %i[channel available reserved consumed released refunded].freeze

    def index? = organization_member?

    def show? = organization_member?

    VISIBILITY = {
      index: { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } },
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?

        scope.where(organization_id: user.organizations.where(archived: false).select(:id))
      end
    end

    private

    def organization_member?
      return true if user&.super_admin?
      organization = record.respond_to?(:organization) ? record.organization : nil
      organization && user&.has_role_in?(organization, :owner, :admin, :manager)
    end
  end
end
