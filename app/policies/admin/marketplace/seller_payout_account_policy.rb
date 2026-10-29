# frozen_string_literal: true

module Admin
  module Marketplace
    # Restricts seller destination review to the dedicated Marketplace payout
    # permission while keeping beneficiary credentials outside admin responses.
    class SellerPayoutAccountPolicy < Core::ApplicationPolicy
      SAFE_FIELDS = %i[
      id user_id type provider bank_slug account_label status verification_source
        is_default verified_at last_used_at created_at updated_at
      ].freeze

      def index? = allowed?

      def show? = allowed?

      def verify? = allowed?

      VISIBILITY = {
        index: { admin: { fields: SAFE_FIELDS, include: [] }, default: { fields: [], include: [] } },
        show: { admin: { fields: SAFE_FIELDS, include: [] }, default: { fields: [], include: [] } },
        verify: { admin: { fields: SAFE_FIELDS, include: [] }, default: { fields: [], include: [] } }
      }.freeze

      class Scope < Core::ApplicationPolicy::Scope
        def resolve
          return scope.none unless user
          return scope.all if user.super_admin? || user.has_permission?(PERMISSION)

          scope.none
        end
      end

      private

      PERMISSION = "marketplace.seller_payout_account.verify"

      def allowed?
        user&.super_admin? || user&.has_permission?(PERMISSION) == true
      end
    end
  end
end
