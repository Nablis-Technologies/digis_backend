# frozen_string_literal: true

module Finance
  # Posts a successful item refund as a negative organizer fact. Unaccepted
  # payment reversals are deliberately ignored because they never posted sale
  # proceeds and therefore must not manufacture an organizer loss.
  class PostRefund < Core::BaseService
    include Finance::LedgerPostingSupport

    def initialize(refund:, at: Time.current)
      @refund_id = refund.id
      @at = at.to_time.utc
    end

    def call
      entry = ActiveRecord::Base.transaction do
        refund = Orders::Refund.lock.find(@refund_id)
        payment = Orders::Payment.lock.find(refund.payment_id)
        next if payment.billing_payment?

        order = Orders::Order.lock.find(payment.order_id)
        event = Events::Event.lock.find(order.event_id)
        next unless refund.status == "succeeded" && refund.type == "item_refund" && payment.accepted_at.present?

        create_entry!(
          organization_id: event.organization_id,
          event_id: event.id,
          order_id: order.id,
          payment_id: payment.id,
          refund_id: refund.id,
          type: "refund",
          amount_minor: -convert_to_settlement(refund.amount_minor, order),
          currency: order.settlement_currency,
          available_at: at,
          idempotency_key: "finance-refund-#{refund.id}",
          description: entry_description(:refund),
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

    attr_reader :at
  end
end
