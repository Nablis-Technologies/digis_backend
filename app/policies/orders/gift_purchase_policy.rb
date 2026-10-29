# frozen_string_literal: true

module Orders
  class GiftPurchasePolicy < Core::ApplicationPolicy
    STATUS_FIELDS = %i[id status expires_at delivery_status delivered_at claimed_at].freeze

    VISIBILITY = {
      show: { default: { fields: STATUS_FIELDS, include: [] } },
      resend: { default: { fields: STATUS_FIELDS, include: [] } }
    }.freeze

    def show? = payer?

    def resend? = payer? && record.status.in?(%w[ready claimed]) && record.expires_at > Time.current

    private

    def payer?
      record.order_item&.order&.buyer_user_id == user&.id
    end
  end
end
