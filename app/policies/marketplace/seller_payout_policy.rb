# frozen_string_literal: true

module Marketplace
  # Seller payout commands share the Finance permission boundary for dispatch
  # and reconciliation. Sellers can inspect their own payout lifecycle, but
  # cannot trigger provider-side operations or bypass reserve checks.
  class SellerPayoutPolicy < Core::ApplicationPolicy
    SAFE_FIELDS = %i[
      id seller_user_id seller_payout_account_id provider amount_minor currency status requested_at processed_at
      created_at updated_at
    ].freeze

    def index? = payout_access?

    def show? = payout_access?

    def create? = record.seller_user_id == user&.id

    def dispatch? = finance_permission?("finance.payout.dispatch")

    def reconcile? = finance_permission?("finance.payout.reconcile")

    VISIBILITY = {
      index: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      show: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      create: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      dispatch: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      reconcile: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if platform_admin?

        scope.where(seller_user_id: user.id)
      end

      private

      def platform_admin?
        user.super_admin? || user.has_role?("ADMIN") || user.has_role?("CORE_ADMIN")
      end
    end

    class SellerScope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user

        scope.where(seller_user_id: user.id)
      end
    end

    private

    def payout_access?
      platform_admin? || record.seller_user_id == user&.id
    end

    def platform_admin?
      user&.super_admin? || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
    end

    def finance_permission?(permission)
      platform_admin? || user&.has_permission?(permission) == true
    end
  end
end
