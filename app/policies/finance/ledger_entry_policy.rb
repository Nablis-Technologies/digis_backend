# frozen_string_literal: true

module Finance
  # Authorizes organizer ledger reports by active organization membership. The
  # ledger is immutable evidence, so this policy exposes reads only and never
  # turns a report endpoint into an accounting mutation.
  class LedgerEntryPolicy < Core::ApplicationPolicy
    SAFE_FIELDS = %i[
      id organization_id event_id order_id refund_id type amount_minor currency
      available_at description event created_at
    ].freeze

    def index? = organization_access?

    def show? = organization_access?

    VISIBILITY = {
      index: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      show: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      ledger_entries: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } }
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
      return true if user.has_permission?("finance.payout.dispatch")

      Organizations::Membership.where(
        user:, organization: record.organization, status: "active", role: %w[owner admin manager]
      ).exists?
    end
  end
end
