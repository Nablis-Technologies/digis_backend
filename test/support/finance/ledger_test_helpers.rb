# frozen_string_literal: true

module Finance
  # Builds the smallest event/order/payment graph needed by finance ledger
  # tests without introducing runtime accounting facts through fixtures.
  module LedgerTestHelpers
    private

    # Non-transactional payment races commit ledger facts so worker connections
    # can observe them. Test teardown may remove only those isolated facts;
    # production ledger rows remain append-only and are never cleaned this way.
    def cleanup_payment_ledger_entries(payment_ids:)
      payment_ids = Array(payment_ids).compact
      return if payment_ids.empty?

      connection = Finance::ApplicationRecord.connection
      connection.execute(
        "ALTER TABLE finance_ledger_entries DISABLE TRIGGER trg_finance_ledger_entry_immutable"
      )
      begin
        ledger_entry_ids = Finance::LedgerEntry.where(payment_id: payment_ids).pluck(:id)
        Finance::PayoutAllocation.where(ledger_entry_id: ledger_entry_ids).delete_all
        Finance::LedgerEntry.where(id: ledger_entry_ids).delete_all
      ensure
        connection.execute(
          "ALTER TABLE finance_ledger_entries ENABLE TRIGGER trg_finance_ledger_entry_immutable"
        )
      end
    end

    def create_ledger_order(status: "fulfilled", settlement_total_minor: 9_500)
      event = events_events(:ready_listing)
      order = Orders::Order.create!(
        event:,
        buyer_user: core_users(:attendee),
        sales_channel: "online",
        status: "draft",
        closed_reason: nil,
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 10_000,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 10_000,
        settlement_currency: "ETB",
        settlement_total_minor:,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now,
        paid_at: nil,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )

      yield order if block_given?
      order.update_columns(
        status:,
        closed_reason: status == "cancelled" ? "test_cleanup" : nil,
        paid_at: Orders::Order::PAID_STATUSES.include?(status) ? Time.current : nil
      )
      order.reload
    end

    def create_accepted_payment(order:, amount_minor: order.total_minor)
      Orders::Payment.create!(
        order:,
        attempt_number: 1,
        provider: "chapa",
        payment_method: "telebirr",
        status: "succeeded",
        amount_minor:,
        currency: order.charge_currency,
        commercial_signature: order.commercial_signature,
        buyer_fee_minor: 0,
        organizer_fee_minor: 0,
        idempotency_key: "ledger-payment-#{SecureRandom.hex(8)}",
        provider_reference: "ledger-provider-#{SecureRandom.hex(8)}",
        accepted_at: Time.current,
        succeeded_at: Time.current,
        settlement_grace_minutes: 5,
        settlement_grace_expires_at: order.expires_at + 5.minutes
      )
    end

    def create_organizer_adjustment(order:, type: "platform_fee", amount_minor: 500)
      with_draft_order(order) do
        Orders::OrderAdjustment.create!(
          order:,
          type:,
          label: "Organizer adjustment",
          charged_to: "organizer",
          amount_minor:,
          currency: order.charge_currency,
          refund_policy: "nonrefundable",
          calculation_type: "fixed",
          fixed_amount_minor: amount_minor,
          funded_by: "organizer",
          source_type: "Commercial::FeeComponent",
          source_id: SecureRandom.uuid,
          resolution_evidence: {}
        )
      end
    end

    def create_refund_for(order:, payment:, amount_minor: 3_000)
      product = Catalog::EventProduct.create!(
        event: order.event,
        name: "Ledger refund product #{SecureRandom.hex(4)}",
        type: "merchandise",
        status: "active",
        inventory_mode: "unlimited"
      )
      item = with_draft_order(order) do
        Orders::OrderItem.create!(
          order:,
          event_product: product,
          name_snapshot: product.name,
          type_snapshot: "merchandise",
          quantity: 1,
          base_currency: "ETB",
          base_unit_amount_minor: order.subtotal_minor,
          charge_currency: "ETB",
          charge_unit_amount_minor: order.subtotal_minor,
          exchange_rate: 1,
          discount_minor: 0,
          total_minor: order.subtotal_minor,
          fulfillment_status: "fulfilled"
        )
      end
      ActiveRecord::Base.transaction do
        refund = Orders::Refund.create!(
          payment:,
          type: "item_refund",
          idempotency_key: "ledger-refund-#{SecureRandom.hex(8)}",
          amount_minor:,
          currency: order.charge_currency,
          status: "succeeded",
          reason_code: "event_cancellation"
        )
        Orders::RefundItem.create!(
          refund:,
          order_item: item,
          quantity: 1,
          subtotal_minor: amount_minor,
          amount_minor:
        )
        refund
      end
    end

    # Existing order snapshots are intentionally immutable. This helper opens
    # only the test fixture's draft window so immutable child snapshots can be
    # assembled without weakening the production invariants.
    def with_draft_order(order)
      previous_status = order.status
      previous_closed_reason = order.closed_reason
      previous_paid_at = order.paid_at
      order.update_columns(status: "draft", closed_reason: nil, paid_at: nil)
      yield
    ensure
      order.update_columns(
        status: previous_status,
        closed_reason: previous_closed_reason,
        paid_at: previous_paid_at
      )
      order.reload
    end
  end
end
