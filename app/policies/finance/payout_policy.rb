# frozen_string_literal: true

module Finance
  # Keeps organizer payout requests separate from platform treasury actions.
  # Organizers may request and inspect their own payouts; dispatch,
  # reconciliation, and no-balance approvals require explicit finance
  # permissions and therefore cannot be granted by organization membership.
  class PayoutPolicy < Core::ApplicationPolicy
    SAFE_FIELDS = %i[
      id organization_id currency status amount_minor period_start period_end
      requested_at paid_at created_at updated_at
    ].freeze

    def index? = organization_access?

    def show? = organization_access?

    def create? = organization_access?

    def dispatch? = finance_permission?("finance.payout.dispatch")

    def reconcile? = finance_permission?("finance.payout.reconcile")

    def approve_no_balance_api? = finance_permission?("finance.payout.approve_no_balance_api")

    VISIBILITY = {
      index: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      show: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      create: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      dispatch_payout: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      dispatch: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      reconcile: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      approve_no_balance_api: {
        default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] }
      }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if finance_admin?

        scope.where(organization_id: managed_organization_ids)
      end

      private

      def finance_admin?
        user.has_permission?("finance.payout.dispatch")
      end

      def managed_organization_ids
        Organizations::Membership.where(user:, status: "active", role: %w[owner admin manager])
          .select(:organization_id)
      end
    end

    private

    def organization_access?
      return false unless user && record.organization
      return true if finance_admin?

      Organizations::Membership.where(
        user:, organization: record.organization, status: "active", role: %w[owner admin manager]
      ).exists?
    end

    def finance_admin?
      user.has_permission?("finance.payout.dispatch")
    end

    def finance_permission?(permission)
      user&.has_permission?(permission) == true
    end
  end
end
