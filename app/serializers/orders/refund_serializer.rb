# frozen_string_literal: true

module Orders
  # Includes operational refund attributes so policy visibility can make the
  # buyer/organizer boundary explicit. Provider fees, retry timing, and raw
  # recovery reasons are never visible on the default API profile.
  class RefundSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :payment_id, :event_cancellation_id, :type, :provider_reference,
               :amount_minor, :currency, :status, :provider_fee_minor,
               :provider_fee_currency, :provider_fee_recorded_at, :pending_reason,
               :next_retry_at, :reason_code, :created_at, :updated_at
  end
end
