# frozen_string_literal: true

module Finance
  # Exposes the organizer-safe payout lifecycle. Provider references,
  # idempotency keys, and failure diagnostics remain treasury-only data.
  class PayoutSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :organization_id, :payout_account_id, :currency, :status, :amount_minor, :provider,
               :provider_reference, :idempotency_key, :period_start, :period_end,
               :requested_at, :paid_at, :failure_code, :payout_account, :status_reason_code,
               :created_at, :updated_at

    attribute :payout_account do
      account = object.payout_account
      next unless account

      {
        id: account.id,
        type: account.type,
        provider: account.provider,
        bank_slug: account.bank_slug,
        account_label: account.account_label,
        status: account.status,
        is_default: account.is_default,
        verified_at: account.verified_at
      }
    end

    attribute :status_reason_code do
      case object.failure_code.to_s
      when "insufficient_balance" then "provider_liquidity"
      when "invalid_account" then "destination_invalid"
      when "timeout", "unknown" then "provider_pending"
      when "" then nil
      else "provider_error"
      end
    end
  end
end
