# frozen_string_literal: true

module Marketplace
  # Derives seller balances from immutable ledger rows and payout intents. A
  # pending/processing payout reserves its net requested amount; allocation
  # rows are not summed because negative correction facts are allocated by
  # absolute value while the payout itself is a signed balance obligation.
  class SellerBalanceReport < Core::BaseService
    def initialize(seller:, currency: nil)
      @seller_id = seller.id
      @currency = currency.to_s.strip.upcase.presence
    end

    def call
      ledger_totals = ledger_scope.group(:currency).sum(:amount_minor)
      reserved_totals = reserved_scope.group(:currency).sum(:amount_minor)
      currencies = (ledger_totals.keys | reserved_totals.keys).sort

      success(currencies.map do |currency|
        ledger_total = ledger_totals.fetch(currency, 0)
        reserved = reserved_totals.fetch(currency, 0)
        {
          currency:, ledger_total_minor: ledger_total,
          reserved_minor: reserved, available_minor: ledger_total - reserved
        }
      end)
    end

    private

    attr_reader :seller_id, :currency

    def ledger_scope
      scope = SellerLedgerEntry.where(seller_user_id: seller_id)
      currency.present? ? scope.where(currency:) : scope
    end

    def reserved_scope
      scope = SellerPayout.where(seller_user_id: seller_id, status: %w[pending processing])
      currency.present? ? scope.where(currency:) : scope
    end
  end
end
