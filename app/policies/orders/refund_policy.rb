# frozen_string_literal: true

module Orders
  # Separates refund visibility from the payment/order aggregates. Buyers can
  # inspect only their own safe obligation status; organizers can inspect
  # refunds belonging to their events, while provider and recovery evidence
  # remains outside every non-operational response.
  class RefundPolicy < Core::ApplicationPolicy
    SAFE_FIELDS = %i[id amount_minor currency status reason_code created_at updated_at].freeze

    def index? = user.present?

    def show? = visible_to_requester?

    def create? = false

    VISIBILITY = {
      index: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      show: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } },
      create: { default: { fields: SAFE_FIELDS, include: [] }, admin: { fields: SAFE_FIELDS, include: [] } }
    }.freeze

    class Scope < Core::ApplicationPolicy::Scope
      def resolve
        return scope.none unless user
        return scope.all if platform_admin?

        buyer_payment_ids = Orders::Payment.where(
          order_id: Orders::Order.where(buyer_user_id: user.id).select(:id)
        ).select(:id)
        organizer_event_ids = Events::Event.where(
          organization_id: managed_organization_ids
        ).select(:id)
        organizer_payment_ids = Orders::Payment.where(
          order_id: Orders::Order.where(event_id: organizer_event_ids).select(:id)
        ).select(:id)

        scope.where(payment_id: buyer_payment_ids)
          .or(scope.where(payment_id: organizer_payment_ids))
          .distinct
      end

      private

      def platform_admin?
        user.has_role?("SUPER_ADMIN") || user.has_role?("ADMIN") || user.has_role?("CORE_ADMIN")
      end

      def managed_organization_ids
        Organizations::Membership.where(user:, status: "active", role: %w[owner admin manager])
          .select(:organization_id)
      end
    end

    private

    def visible_to_requester?
      return false unless record.payment&.order
      return true if platform_admin?
      return true if buyer?

      managed_event?
    end

    def buyer?
      record.payment.order.buyer_user_id == user&.id
    end

    def platform_admin?
      user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
    end

    def managed_event?
      event = record.payment.order.event
      return false unless event

      Events::AuthorizationResolver.organization_admin_or_owner?(user, event)
    end
  end
end
