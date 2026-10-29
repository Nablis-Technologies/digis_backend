# frozen_string_literal: true

module Marketplace
  # A seller may manage only their own encrypted payout destinations. Raw
  # beneficiary credentials are never part of this policy's visible fields.
  class SellerPayoutAccountPolicy < Core::ApplicationPolicy
    SAFE_FIELDS = %i[
      id user_id type provider bank_slug account_label status verification_source
      is_default verified_at last_used_at created_at updated_at
    ].freeze

    def index? = account_access?

    def destinations? = account_access?

    def show? = account_access?

    def create? = platform_admin? || record.user_id == user&.id

    def set_default? = account_access?

    VISIBILITY = {
      index: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      destinations: { default: { fields: [], include: [] }, admin: { fields: [], include: [] } },
      show: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      create: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      set_default: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if platform_admin?

        scope.where(user_id: user.id)
      end

      private

      def platform_admin?
        user.super_admin? || user.has_role?("ADMIN") || user.has_role?("CORE_ADMIN")
      end
    end

    private

    def account_access?
      platform_admin? || record.user_id == user&.id
    end

    def platform_admin?
      user&.super_admin? || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
    end
  end
end
