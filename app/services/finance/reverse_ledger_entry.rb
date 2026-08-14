# frozen_string_literal: true

module Finance
  # Corrects one historical fact by appending its exact opposite. The source
  # row remains untouched, preserving a complete audit trail for reconciliation.
  class ReverseLedgerEntry < Core::BaseService
    include Finance::LedgerPostingSupport

    def initialize(entry:, idempotency_key: nil, at: Time.current)
      @entry_id = entry.id
      @idempotency_key = idempotency_key
      @at = at.to_time.utc
    end

    def call
      reversal = ActiveRecord::Base.transaction do
        entry = Finance::LedgerEntry.lock.find(@entry_id)
        create_entry!(
          organization_id: entry.organization_id,
          event_id: entry.event_id,
          order_id: entry.order_id,
          payment_id: entry.payment_id,
          refund_id: entry.refund_id,
          reverses_entry_id: entry.id,
          type: "adjustment",
          amount_minor: -entry.amount_minor,
          currency: entry.currency,
          available_at: at,
          idempotency_key: idempotency_key || "finance-reversal-#{entry.id}",
          description: entry_description(:reversal),
          created_at: at
        )
      end
      success(reversal)
    rescue ActiveRecord::RecordInvalid
      failure(finance_error(:ledger_entry_invalid, code: "ledger_entry_invalid", status: :conflict))
    rescue ActiveRecord::RecordNotFound
      failure(finance_error(:source_not_found, code: "source_not_found", status: :not_found))
    end

    private

    attr_reader :at, :idempotency_key
  end
end
