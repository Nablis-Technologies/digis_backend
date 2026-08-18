# frozen_string_literal: true

module Finance
  # Posts the accepted payment's immutable settlement snapshot. The gross sale
  # and each organizer-charged adjustment are separate rows so reporting can
  # explain the net amount without recalculating current Commercial rules.
  class PostAcceptedSale < Core::BaseService
    include Finance::LedgerPostingSupport

    ORGANIZER_ADJUSTMENT_TYPES = %w[
      service_fee platform_fee processing_fee resale_platform_fee subsidy tax manual_adjustment
    ].freeze

    def initialize(payment:, at: Time.current)
      @payment_id = payment.id
      @at = at.to_time.utc
    end

    def call
      entries = ActiveRecord::Base.transaction do
        order_id = Orders::Payment.where(id: @payment_id).pick(:order_id)
        order = Orders::Order.lock.find(order_id)
        event = Events::Event.lock.find(order.event_id)
        payment = Orders::Payment.lock.find(@payment_id)
        next [] unless payment.status == "succeeded" && payment.accepted_at.present?

        adjustments = Orders::OrderAdjustment.where(
          order_id: order.id, charged_to: "organizer", type: ORGANIZER_ADJUSTMENT_TYPES
        ).order(:id).lock.to_a
        adjustment_attributes = adjustments.filter_map { |adjustment|
          next if adjustment.amount_minor.zero?

          adjustment_attributes(adjustment, order, event, payment)
        }
        sale_amount = order.settlement_total_minor - adjustment_attributes.sum { |row| row.fetch(:amount_minor) }
        raise ActiveRecord::RecordInvalid, Finance::LedgerEntry.new(amount_minor: sale_amount) unless sale_amount.positive?

        sale = create_entry!(base_attributes(order:, event:, payment:, amount_minor: sale_amount,
          type: "sale", available_at: sale_available_at(order, at),
          idempotency_key: "finance-sale-payment-#{payment.id}",
          description: entry_description(:sale)))
        [ sale ] + adjustment_attributes.map { |attributes| create_entry!(attributes) }
      end
      success(entries)
    rescue ActiveRecord::RecordInvalid
      failure(finance_error(:ledger_entry_invalid, code: "ledger_entry_invalid", status: :conflict))
    rescue ActiveRecord::RecordNotFound
      failure(finance_error(:source_not_found, code: "source_not_found", status: :not_found))
    end

    private

    attr_reader :at

    def base_attributes(order:, event:, payment:, amount_minor:, type:, available_at:, idempotency_key:, description:)
      {
        organization_id: event.organization_id,
        event_id: event.id,
        order_id: order.id,
        payment_id: payment.id,
        type:,
        amount_minor:,
        currency: order.settlement_currency,
        available_at:,
        idempotency_key:,
        description:,
        created_at: at
      }
    end

    def adjustment_attributes(adjustment, order, event, payment)
      amount_minor = -convert_to_settlement(adjustment.amount_minor, order)
      type = %w[platform_fee processing_fee].include?(adjustment.type) ? adjustment.type : "adjustment"
      base_attributes(
        order:, event:, payment:, amount_minor:, type:,
        available_at: at,
        idempotency_key: "finance-adjustment-payment-#{@payment_id}-#{adjustment.id}",
        description: entry_description(:organizer_adjustment, type: adjustment.type)
      )
    end
  end
end
