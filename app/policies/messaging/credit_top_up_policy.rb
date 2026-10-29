# frozen_string_literal: true

module Messaging
  class CreditTopUpPolicy < Core::ApplicationPolicy
    FIELDS = %i[id organization_id credit_account_id rate_version_id channel quantity currency amount_minor
                price_digest status provider_reference created_at updated_at].freeze

    def create? = organization_member?

    def show? = organization_member?

    def estimate? = organization_member?

    VISIBILITY = {
      create: { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } },
      show: { default: { fields: FIELDS, include: [] }, admin: { fields: FIELDS, include: [] } },
      estimate: { default: { fields: %i[channel quantity currency amount_minor rate_version_id scope tier], include: [] },
                  admin: { fields: %i[channel quantity currency amount_minor rate_version_id scope tier], include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if user.super_admin?

        scope.where(organization_id: user.organizations.select(:id))
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
