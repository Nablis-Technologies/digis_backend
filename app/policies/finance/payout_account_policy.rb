# frozen_string_literal: true

module Finance
  # Separates organization destination management from Finance verification.
  # The policy never exposes encrypted beneficiary values.
  class PayoutAccountPolicy < Core::ApplicationPolicy
    SAFE_FIELDS = %i[
      id organization_id type provider bank_code account_label status
      verification_source is_default verified_at last_used_at created_at updated_at
    ].freeze

    def index? = organization_access?

    def create? = organization_admin?

    def verify? = finance_admin?

    def set_default? = organization_admin?

    def suspend? = finance_admin?

    def close? = finance_admin?

    VISIBILITY = {
      index: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      create: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      verify: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      set_default: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      suspend: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      close: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if finance_admin?

        scope.where(organization_id: managed_organization_ids)
      end

      private

      def finance_admin?
        user.has_permission?("finance.payout_account.verify")
      end

      def managed_organization_ids
        Organizations::Membership.where(user:, status: "active", role: %w[owner admin manager])
          .select(:organization_id)
      end
    end

    private

    def organization_access?
      finance_admin? || organization_admin?
    end

    def organization_admin?
      Events::AuthorizationResolver.organization_admin?(user, record.organization)
    end

    def finance_admin?
      user&.has_permission?("finance.payout_account.verify") == true
    end
  end
end
