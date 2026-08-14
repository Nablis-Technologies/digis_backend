# frozen_string_literal: true

module Orders
  # Immutable reconciliation value for one refund item or one date portion.
  # The amount is always derived from the original subtotal and signed buyer
  # adjustment share; current pricing or refund policy is never consulted.
  RefundAmount = Data.define(:subtotal_minor, :adjustment_minor, :amount_minor, :currency) do
    def initialize(subtotal_minor:, adjustment_minor:, amount_minor:, currency:)
      fail ArgumentError, I18n.t("orders.refunds.errors.refund_does_not_reconcile") unless amount_minor == subtotal_minor + adjustment_minor
      fail ArgumentError, I18n.t("orders.refunds.errors.refund_amount_not_positive") unless amount_minor.positive?

      super
    end
  end
end
