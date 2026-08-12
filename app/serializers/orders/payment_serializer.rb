# frozen_string_literal: true

module Orders
  # Serializes the buyer-safe provider attempt state. Internal Commercial
  # signatures, idempotency keys, fee allocation, and raw gateway payloads are
  # intentionally excluded; operational evidence belongs to later surfaces.
  class PaymentSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :order_id, :attempt_number, :provider, :payment_method,
               :status, :amount_minor, :currency, :provider_reference,
               :settlement_grace_minutes, :settlement_grace_expires_at,
               :created_at, :updated_at
  end
end
