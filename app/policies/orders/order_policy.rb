# frozen_string_literal: true

module Orders
  # Restricts checkout to a buyer who can see the event's public sale surface.
  # Administrative identities may inspect/order on behalf of a buyer only when
  # the caller is explicitly used as that buyer by the application boundary.
  class OrderPolicy < Core::ApplicationPolicy
    def quote? = checkout_buyer?

    def create? = checkout_buyer?

    def show? = admin? || buyer?

    def restart? = buyer? && record.status.in?(%w[draft pending_payment])

    def start_payment_attempt? = buyer? && record.pending_payment?

    VISIBILITY = {
      create: {
        default: {
          fields: %i[
            id event_id status sales_channel charge_currency subtotal_minor discount_minor
            subsidy_minor fee_minor tax_minor adjustment_minor total_minor expires_at
            paid_at created_at updated_at
          ],
          include: []
        },
        admin: { fields: :all, include: [] }
      },
      restart: {
        default: {
          fields: %i[
            id event_id status sales_channel charge_currency subtotal_minor discount_minor
            subsidy_minor fee_minor tax_minor adjustment_minor total_minor expires_at
            paid_at created_at updated_at
          ],
          include: []
        },
        admin: { fields: :all, include: [] }
      },
      show: {
        default: {
          fields: %i[
            id event_id status sales_channel charge_currency subtotal_minor discount_minor
            subsidy_minor fee_minor tax_minor adjustment_minor total_minor expires_at
            paid_at created_at updated_at
          ],
          include: []
        },
        admin: { fields: :all, include: [] }
      }
    }.freeze

    private

    def checkout_buyer?
      return false unless user && record.event && record.buyer_user
      return true if admin?

      buyer? && record.event.published? && record.event.visibility == "public"
    end

    def buyer?
      record.buyer_user_id.to_s == user&.id.to_s
    end

    def admin?
      user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
    end
  end
end
