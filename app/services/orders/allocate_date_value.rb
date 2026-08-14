# frozen_string_literal: true

module Orders
  # Allocates one immutable item's subtotal and signed buyer-adjustment value
  # over its snapshotted product-date basis points. Subtotal and adjustment are
  # rounded independently, then recombined so every date and the full item
  # reconcile exactly in the original charge currency.
  class AllocateDateValue < Core::BaseService
    Allocation = Data.define(:event_date_id, :refund_amount)

    def initialize(subtotal_minor:, adjustment_minor:, currency:, date_allocations:)
      @subtotal_minor = subtotal_minor
      @adjustment_minor = adjustment_minor
      @currency = currency.to_s.upcase
      @date_allocations = date_allocations.to_a.map { |allocation| normalize_allocation(allocation) }
    end

    def call
      validate!
      subtotal_values = allocate_weighted(subtotal_minor)
      adjustment_values = allocate_signed(adjustment_minor)
      amounts = date_allocations.sort_by { |allocation| allocation[:id] }.map do |allocation|
        date_id = allocation[:id]
        refund_amount = RefundAmount.new(
          subtotal_minor: subtotal_values.fetch(date_id),
          adjustment_minor: adjustment_values.fetch(date_id),
          amount_minor: subtotal_values.fetch(date_id) + adjustment_values.fetch(date_id),
          currency:
        )
        Allocation.new(event_date_id: date_id, refund_amount:)
      end

      success(amounts.freeze)
    end

    private

    attr_reader :subtotal_minor, :adjustment_minor, :currency, :date_allocations

    def normalize_allocation(allocation)
      {
        id: value_for(allocation, :event_date_id, fallback: :id).to_s,
        weight: value_for(allocation, :allocation_basis_points)
      }
    end

    def value_for(record, key, fallback: nil)
      return record.public_send(key) if record.respond_to?(key)
      return record.public_send(fallback) if fallback && record.respond_to?(fallback)

      attributes = record.to_h
      attributes[key] || attributes[key.to_s] || (fallback && (attributes[fallback] || attributes[fallback.to_s]))
    end

    def validate!
      raise ArgumentError, I18n.t("orders.refunds.errors.subtotal_invalid") unless subtotal_minor.is_a?(Integer) && subtotal_minor >= 0
      raise ArgumentError, I18n.t("orders.refunds.errors.adjustment_invalid") unless adjustment_minor.is_a?(Integer)
      raise ArgumentError, I18n.t("orders.refunds.errors.currency_invalid") unless currency.match?(/\A[A-Z]{3}\z/)
      raise ArgumentError, I18n.t("orders.refunds.errors.date_allocations_required") if date_allocations.empty?
      raise ArgumentError, I18n.t("orders.refunds.errors.date_allocation_ids_not_unique") unless date_allocations.map { |allocation| allocation[:id] }.uniq.length == date_allocations.length
      raise ArgumentError, I18n.t("orders.refunds.errors.date_allocation_shares_invalid") unless date_allocations.sum { |allocation| allocation[:weight].to_i } == LargestRemainderAllocator::BASIS_POINTS
      raise ArgumentError, I18n.t("orders.refunds.errors.date_allocation_shares_nonpositive") unless date_allocations.all? { |allocation| allocation[:id].present? && allocation[:weight].is_a?(Integer) && allocation[:weight].positive? }
    end

    def allocate_signed(amount_minor)
      return date_allocations.to_h { |allocation| [ allocation[:id], 0 ] } if amount_minor.zero?

      values = allocate_weighted(amount_minor.abs)
      values.transform_values { |value| amount_minor.negative? ? -value : value }
    end

    def allocate_weighted(amount_minor)
      result = LargestRemainderAllocator.weighted(
        total_minor: amount_minor,
        allocations: date_allocations.map { |allocation| { id: allocation[:id], weight: allocation[:weight] } }
      )
      result.value.to_h { |allocation| [ allocation.id, allocation.amount_minor ] }
    end
  end
end
