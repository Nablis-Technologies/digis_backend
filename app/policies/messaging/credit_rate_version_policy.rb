# frozen_string_literal: true

module Messaging
  class CreditRateVersionPolicy < Core::ApplicationPolicy
    FIELDS = %i[id organization_id channel version currency unit_price_minor country_code
                volume_tiers effective_from effective_until status created_at].freeze

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

        scope.where(organization_id: user.organizations.select(:id)).or(scope.where(organization_id: nil))
      end
    end

    private

    def organization_member?
      return true if user&.super_admin?
      organization = record.organization
      organization && user&.has_role_in?(organization, :owner, :admin, :manager)
    end
  end
end
