# frozen_string_literal: true

module Catalog
  # Aggregates immutable paid order-item and successful refund facts for one
  # event. Amounts stay in each item's snapshotted charge currency; the order's
  # settlement currency is returned separately because settlement is stored at
  # order level and cannot be reconstructed honestly per item without a new
  # persisted allocation contract.
  class AddOnSalesReport < Core::BaseService
    Row = Data.define(
      :product_id, :type, :name, :quantity, :gross_minor, :refunded_minor,
      :net_minor, :currency, :settlement_currency
    )
    ADD_ON_TYPES = %w[parking merchandise food donation digital_addon other].freeze
    FILTER_CURRENCIES = %r{\A[A-Z]{3}\z}

    def initialize(event:, filters: {})
      @event = event
      @filters = filters.to_h.symbolize_keys
    end

    def call
      return failure(error(:event_required)) unless @event.is_a?(Events::Event)
      return failure(error(:invalid_filter)) unless filters_valid?

      success(rows)
    end

    private

    def rows
      relation = base_scope
      relation = relation.where(type_snapshot: filters[:type]) if filters[:type]
      relation = relation.where(charge_currency: filters[:currency]) if filters[:currency]
      relation = relation.joins(:order).where(orders_orders: { settlement_currency: filters[:settlement_currency] }) if filters[:settlement_currency]

      Orders::OrderItem.connection.select_all(relation.to_sql).map do |row|
        gross_minor = row.fetch("gross_minor").to_i
        refunded_minor = row.fetch("refunded_minor").to_i
        Row.new(
          product_id: row.fetch("product_id"),
          type: row.fetch("type"),
          name: row.fetch("name"),
          quantity: row.fetch("quantity").to_i,
          gross_minor:,
          refunded_minor:,
          net_minor: gross_minor - refunded_minor,
          currency: row.fetch("currency"),
          settlement_currency: row.fetch("settlement_currency")
        )
      end
    end

    def base_scope
      refund_totals = Orders::RefundItem
        .joins(:refund)
        .where(orders_refunds: { status: "succeeded" })
        .select(
          "orders_refund_items.order_item_id",
          "SUM(orders_refund_items.amount_minor) AS refunded_minor"
        )
        .group("orders_refund_items.order_item_id")

      Orders::OrderItem
        .joins(:order, :event_product)
        .joins("LEFT JOIN (#{refund_totals.to_sql}) refund_totals ON refund_totals.order_item_id = orders_order_items.id")
        .where(orders_orders: { event_id: @event.id, status: Orders::Order::PAID_STATUSES })
        .where.not(type_snapshot: "ticket")
        .select(
          "catalog_event_products.id AS product_id",
          "catalog_event_products.type AS type",
          "catalog_event_products.name AS name",
          "SUM(orders_order_items.quantity) AS quantity",
          "SUM(orders_order_items.total_minor) AS gross_minor",
          "COALESCE(SUM(refund_totals.refunded_minor), 0) AS refunded_minor",
          "orders_order_items.charge_currency AS currency",
          "orders_orders.settlement_currency AS settlement_currency"
        )
        .group(
          "catalog_event_products.id",
          "catalog_event_products.type",
          "catalog_event_products.name",
          "orders_order_items.charge_currency",
          "orders_orders.settlement_currency"
        )
        .order(
          "catalog_event_products.type ASC",
          "catalog_event_products.name ASC",
          "orders_order_items.charge_currency ASC",
          "orders_orders.settlement_currency ASC"
        )
    end

    def filters
      @filters
    end

    def filters_valid?
      filters.keys.all? { |key| %i[type currency settlement_currency].include?(key) } &&
        type_filter_valid? && currency_filter_valid?(filters[:currency]) &&
        currency_filter_valid?(filters[:settlement_currency])
    end

    def type_filter_valid?
      filters[:type].nil? || ADD_ON_TYPES.include?(filters[:type].to_s)
    end

    def currency_filter_valid?(value)
      value.nil? || value.to_s.match?(FILTER_CURRENCIES)
    end

    def error(key)
      Core::BusinessError.new(
        I18n.t("catalog.add_on_sales_report.errors.#{key}"),
        code: key,
        status: :unprocessable_entity
      )
    end
  end
end
