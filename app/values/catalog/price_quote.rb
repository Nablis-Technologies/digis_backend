# frozen_string_literal: true

module Catalog
  # Immutable, deterministic quote evidence for a product in a charge currency.
  # `source_type` is one of "override" (fixed price already in the charge
  # currency), "base" (base price in the charge currency), or "exchange" (base
  # price converted via an exchange rate). The FX evidence (rate id + value)
  # lets an order later persist and verify the exact quote that was shown.
  PriceQuote = Data.define(
    :product_id, :charge_currency, :amount_minor, :source_type,
    :from_currency, :exchange_rate_id, :exchange_rate_value, :at
  )
end
