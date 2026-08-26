# frozen_string_literal: true

module Finance
  # Exposes the organizer-safe payout lifecycle. Provider references,
  # idempotency keys, and failure diagnostics remain treasury-only data.
  class PayoutSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :organization_id, :payout_account_id, :currency, :status, :amount_minor, :provider,
               :provider_reference, :idempotency_key, :period_start, :period_end,
               :requested_at, :paid_at, :failure_code, :created_at, :updated_at
  end
end
