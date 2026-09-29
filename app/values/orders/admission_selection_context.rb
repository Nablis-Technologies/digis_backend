# frozen_string_literal: true

module Orders
  # Server-owned buyer, quote, and identity state shared by the admission
  # selection subcommands inside Create's transaction.
  AdmissionSelectionContext = Data.define(
    :event, :buyer, :actor, :items, :charge_currency, :promotion, :promotion_code,
    :guest, :phone, :phone_confirmation, :guest_otp_verified, :email, :full_name,
    :quoted_at, :idempotency_key
  )
end
