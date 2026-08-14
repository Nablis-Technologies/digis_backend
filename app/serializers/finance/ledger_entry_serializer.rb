# frozen_string_literal: true

module Finance
  # Serializes immutable ledger evidence. The policy removes identifiers that
  # are useful only to treasury operations from organizer-facing reports.
  class LedgerEntrySerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :organization_id, :event_id, :order_id, :payment_id, :refund_id,
               :reverses_entry_id, :type, :amount_minor, :currency, :available_at,
               :idempotency_key, :description, :created_at
  end
end
