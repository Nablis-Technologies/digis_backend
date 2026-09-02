# frozen_string_literal: true

module Finance
  # Derives organizer balances from immutable ledger facts and still-reserved
  # payout allocations. It intentionally does not read provider balances or
  # persist a mutable balance counter, so a report cannot become a second
  # source of financial truth.
  class BalanceReport < Core::BaseService
    def initialize(organization:, currency: nil, at: Time.current)
      @organization_id = organization.id
      @currency = currency.to_s.strip.upcase.presence
      @at = at.to_time
    end

    def call
      ledger_totals = ledger_scope.group(:currency).sum(:amount_minor)
      reserved_totals = reserved_scope.group("finance_payouts.currency").sum(:amount_minor)
      pending_totals = pending_scope.group(:currency).sum(:amount_minor)
      pending_dates = pending_scope.group(:currency).minimum(:available_at)
      currencies = (ledger_totals.keys | reserved_totals.keys).sort

      success(currencies.map do |currency|
        ledger_total = ledger_totals.fetch(currency, 0)
        reserved = reserved_totals.fetch(currency, 0)
        {
          currency:, ledger_total_minor: ledger_total,
          reserved_minor: reserved, available_minor: ledger_total - reserved,
          pending_maturity_minor: pending_totals.fetch(currency, 0),
          next_available_at: pending_dates[currency]
        }
      end)
    end

    private

    attr_reader :organization_id, :currency, :at

    def ledger_scope
      scope = Finance::LedgerEntry.where(organization_id:)
      currency.present? ? scope.where(currency:) : scope
    end

    def reserved_scope
      scope = Finance::PayoutAllocation
        .joins(:payout)
        .where(finance_payouts: { organization_id:, status: %w[pending processing] })
        .where(status: "reserved")
      currency.present? ? scope.where(finance_payouts: { currency: }) : scope
    end

    def pending_scope
      ledger_scope.where("available_at > ?", at).where("amount_minor > 0")
    end
  end
end
