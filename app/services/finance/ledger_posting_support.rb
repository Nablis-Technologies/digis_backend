# frozen_string_literal: true

require "bigdecimal"

module Finance
  # Shared mechanics for finance commands. It centralizes conversion from the
  # immutable order FX snapshot and the unique-key insertion boundary so each
  # posting command cannot silently invent a different accounting rule.
  module LedgerPostingSupport
    SALE_BUFFER = 7.days
    MINOR_UNITS = Catalog::Pricing::CurrencyConverter::CURRENCY_MINOR_UNITS

    private

    def create_entry!(attributes)
      idempotency_key = attributes.fetch(:idempotency_key)

      # The lookup handles the common replay without validation work. The
      # unique index handles the race where two retries pass that lookup at
      # the same time; either path returns the original immutable fact.
      Finance::LedgerEntry.find_by(idempotency_key:) || Finance::LedgerEntry.create!(attributes)
    rescue ActiveRecord::RecordNotUnique
      Finance::LedgerEntry.find_by!(idempotency_key:)
    rescue ActiveRecord::RecordInvalid => error
      raise unless error.record.errors.attribute_names == [ :idempotency_key ]

      Finance::LedgerEntry.find_by!(idempotency_key:)
    end

    def convert_to_settlement(amount_minor, order)
      return amount_minor if order.charge_currency == order.settlement_currency

      charge_units = MINOR_UNITS.fetch(order.charge_currency.to_sym, 100)
      settlement_units = MINOR_UNITS.fetch(order.settlement_currency.to_sym, 100)
      (amount_minor.to_d / charge_units / order.exchange_rate * settlement_units)
        .round(0, BigDecimal::ROUND_HALF_UP).to_i
    end

    def sale_available_at(order, at)
      final_event_end = Events::EventDate.where(event_id: order.event_id)
        .where.not(status: "cancelled").maximum(:ends_at)
      [ at, (final_event_end || at) + SALE_BUFFER ].max
    end

    def finance_error(key, code:, status: :unprocessable_entity)
      Core::BusinessError.new(I18n.t("finance.errors.#{key}"), code:, status:)
    end

    def entry_description(key, **options)
      I18n.t("finance.ledger.descriptions.#{key}", **options)
    end
  end
end
