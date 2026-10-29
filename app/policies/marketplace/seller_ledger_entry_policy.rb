# frozen_string_literal: true

module Marketplace
  # Seller ledger visibility is restricted to the seller or platform finance
  # staff. The serializer deliberately removes idempotency and provider data;
  # those facts belong to operational reconciliation, not seller history.
  class SellerLedgerEntryPolicy < Core::ApplicationPolicy
    SAFE_FIELDS = %i[
      id seller_user_id event_id resale_sale_id type amount_minor currency available_at description event created_at
    ].freeze

    def index? = seller_access?

    def show? = seller_access?

    VISIBILITY = {
      index: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      show: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } }
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

    private

    def seller_access?
      platform_admin? || record.seller_user_id == user&.id
    end

    def platform_admin?
      user&.super_admin? || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
    end
  end
end
