# frozen_string_literal: true

module Orders
  # Allocates immutable buyer adjustments to refund items. Order-scoped rows
  # are distributed over positive item values; item-scoped rows stay attached
  # to their original item. Only buyer adjustments whose snapshot permits a
  # refund are included, so organizer settlement rows never enter the buyer
  # refund amount.
  class AllocateRefundAdjustments < Core::BaseService
    Allocation = Data.define(:order_item_id, :order_adjustment_id, :amount_minor)
    REFUNDABLE_POLICIES = %w[refundable event_cancellation_only].freeze

    def initialize(items:, adjustments:)
      @items = items.to_a.map { |item| normalize_item(item) }
      @adjustments = adjustments.to_a.map { |adjustment| normalize_adjustment(adjustment) }
    end

    def call
      eligible_items = items.index_by { |item| item[:id] }
      allocations = eligible_adjustments.flat_map do |adjustment|
        allocate_adjustment(adjustment, eligible_items)
      end

      success(allocations.sort_by { |allocation| [ allocation.order_item_id, allocation.order_adjustment_id ] }.freeze)
    end

    private

    attr_reader :items, :adjustments

    def normalize_item(item)
      {
        id: value_for(item, :id).to_s,
        subtotal_minor: value_for(item, :subtotal_minor)
      }.tap do |normalized|
        raise ArgumentError, I18n.t("orders.refunds.errors.refund_item_id_required") if normalized[:id].blank?
        raise ArgumentError, I18n.t("orders.refunds.errors.refund_item_subtotal_invalid") unless normalized[:subtotal_minor].is_a?(Integer) && normalized[:subtotal_minor] >= 0
      end
    end

    def normalize_adjustment(adjustment)
      {
        id: value_for(adjustment, :id).to_s,
        order_item_id: value_for(adjustment, :order_item_id)&.to_s,
        amount_minor: value_for(adjustment, :amount_minor),
        charged_to: value_for(adjustment, :charged_to).to_s,
        refund_policy: value_for(adjustment, :refund_policy).to_s
      }.tap do |normalized|
        raise ArgumentError, I18n.t("orders.refunds.errors.refund_adjustment_id_required") if normalized[:id].blank?
        raise ArgumentError, I18n.t("orders.refunds.errors.refund_adjustment_amount_invalid") unless normalized[:amount_minor].is_a?(Integer)
      end
    end

    def eligible_adjustments
      adjustments.select do |adjustment|
        adjustment[:amount_minor] != 0 &&
          adjustment[:charged_to] == "buyer" &&
          REFUNDABLE_POLICIES.include?(adjustment[:refund_policy])
      end
    end

    def allocate_adjustment(adjustment, eligible_items)
      item_id = adjustment[:order_item_id]
      return [] if item_id.present? && !eligible_items.key?(item_id)
      return [ Allocation.new(
        order_item_id: item_id,
        order_adjustment_id: adjustment[:id],
        amount_minor: adjustment[:amount_minor]
      ) ] if item_id.present?

      weighted_items = eligible_items.values.select { |item| item[:subtotal_minor].positive? }
      raise ArgumentError, I18n.t("orders.refunds.errors.refund_adjustment_no_eligible_item") if weighted_items.empty?

      result = LargestRemainderAllocator.weighted(
        total_minor: adjustment[:amount_minor].abs,
        allocations: weighted_items.map { |item| { id: item[:id], weight: item[:subtotal_minor] } }
      )
      result.value.filter_map do |allocation|
        amount_minor = adjustment[:amount_minor].negative? ? -allocation.amount_minor : allocation.amount_minor
        next if amount_minor.zero?

        Allocation.new(
          order_item_id: allocation.id,
          order_adjustment_id: adjustment[:id],
          amount_minor:
        )
      end
    end

    def value_for(record, key)
      return record.public_send(key) if record.respond_to?(key)

      attributes = record.to_h
      attributes[key] || attributes[key.to_s]
    end
  end
end
