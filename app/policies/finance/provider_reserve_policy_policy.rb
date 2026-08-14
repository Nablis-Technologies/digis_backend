# frozen_string_literal: true

module Finance
  # Reserve targets are platform configuration, not organizer balances. Only
  # an explicitly permissioned finance administrator can change them.
  class ProviderReservePolicyPolicy < Core::ApplicationPolicy
    SAFE_FIELDS = %i[id provider currency target_minor created_at updated_at].freeze

    def index? = finance_admin?

    def show? = finance_admin?

    def update? = finance_admin?

    VISIBILITY = {
      index: { default: { fields: %i[id provider currency target_minor created_at updated_at], include: [] }, admin: { fields: :all, include: [] } },
      show: { default: { fields: %i[id provider currency target_minor created_at updated_at], include: [] }, admin: { fields: :all, include: [] } },
      update: { default: { fields: %i[id provider currency target_minor created_at updated_at], include: [] }, admin: { fields: :all, include: [] } },
      update_reserve_policy: { default: { fields: %i[id provider currency target_minor created_at updated_at], include: [] }, admin: { fields: :all, include: [] } }
    }.freeze

    private

    def finance_admin?
      user&.has_permission?("finance.reserve_policy.update") == true
    end
  end
end
