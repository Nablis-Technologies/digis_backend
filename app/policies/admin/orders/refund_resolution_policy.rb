# frozen_string_literal: true

module Admin
  module Orders
    class RefundResolutionPolicy < Core::ApplicationPolicy
      FIELDS = %i[id payment_id billing_purchase_id type amount_minor currency status reason_code created_at updated_at].freeze
      PERMISSION = "orders.billing_refund.resolve_manual"

      def resolve_manual? = user&.super_admin? || user&.has_permission?(PERMISSION) == true

      VISIBILITY = {
        resolve_manual: {
          admin: { fields: FIELDS, include: [] },
          default: { fields: [], include: [] }
        }
      }.freeze
    end
  end
end
