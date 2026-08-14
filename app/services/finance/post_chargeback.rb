# frozen_string_literal: true

module Finance
  # Records a provider chargeback against an accepted payment. The command
  # accepts an explicit idempotency key when a provider supplies one; the
  # deterministic fallback keeps the basic single-chargeback path replay-safe.
  class PostChargeback < Core::BaseService
    include Finance::LedgerPostingSupport

    def initialize(payment:, amount_minor:, idempotency_key: nil, at: Time.current)
      @payment_id = payment.id
      @amount_minor = amount_minor
      @idempotency_key = idempotency_key
      @at = at.to_time.utc
    end

    def call
      return failure(finance_error(:chargeback_amount_invalid, code: "chargeback_amount_invalid")) unless amount_minor.is_a?(Integer) && amount_minor.positive?

      entry = ActiveRecord::Base.transaction do
        payment = Orders::Payment.lock.find(@payment_id)
        order = Orders::Order.lock.find(payment.order_id)
        event = Events::Event.lock.find(order.event_id)
        next unless payment.status == "succeeded" && payment.accepted_at.present?

        create_entry!(
          organization_id: event.organization_id,
          event_id: event.id,
          order_id: order.id,
          payment_id: payment.id,
          type: "chargeback",
          amount_minor: -convert_to_settlement(amount_minor, order),
          currency: order.settlement_currency,
          available_at: at,
          idempotency_key: idempotency_key || "finance-chargeback-payment-#{payment.id}-#{amount_minor}",
          description: entry_description(:chargeback),
          created_at: at
        )
      end
      success(entry)
    rescue ActiveRecord::RecordInvalid
      failure(finance_error(:ledger_entry_invalid, code: "ledger_entry_invalid", status: :conflict))
    rescue ActiveRecord::RecordNotFound
      failure(finance_error(:source_not_found, code: "source_not_found", status: :not_found))
    end

    private

    attr_reader :amount_minor, :at, :idempotency_key
  end
end
