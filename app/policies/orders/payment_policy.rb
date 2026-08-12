# frozen_string_literal: true

module Orders
  # Limits payment-attempt serialization to fields needed to continue or
  # display the buyer's own gateway attempt. Commercial evidence, idempotency
  # keys, organizer fees, and raw provider status never belong on this surface.
  class PaymentPolicy < Core::ApplicationPolicy
    VISIBILITY = {
      create: {
        default: {
          fields: %i[
            id order_id attempt_number provider payment_method status amount_minor currency
            provider_reference settlement_grace_minutes settlement_grace_expires_at
            created_at updated_at
          ],
          include: []
        }
      }
    }.freeze

    def create? = buyer?

    def show? = buyer?

    private

    def buyer?
      record.order&.buyer_user_id.to_s == user&.id.to_s
    end
  end
end
