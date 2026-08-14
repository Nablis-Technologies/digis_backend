# frozen_string_literal: true

module Finance
  # Applies the post-provider accounting transition under the payout lock.
  # Provider calls never happen here; this module only makes a durable result
  # idempotent after DispatchPayout or ReconcilePayout has a canonical answer.
  module PayoutSettlement
    private

    def settle_payout_success(payout_id:, provider_reference:, at:)
      ActiveRecord::Base.transaction do
        payout = Finance::Payout.lock.find(payout_id)
        return payout if payout.paid?
        return payout unless payout.processing?

        allocations = Finance::PayoutAllocation
          .where(payout_id: payout.id, status: %w[reserved consumed])
          .order(:id)
          .lock
          .to_a
        validate_payout_total!(payout, allocations)

        payout.update!(
          status: "paid",
          provider_reference: provider_reference,
          paid_at: at,
          failure_code: nil
        )
        allocations.each { |allocation| allocation.update!(status: "consumed", consumed_at: at, released_at: nil) }
        create_payout_ledger_entry!(payout, at:)
        payout
      end
    end

    def settle_payout_failure(payout_id:, status:, failure_code:, at:)
      ActiveRecord::Base.transaction do
        payout = Finance::Payout.lock.find(payout_id)
        return payout if payout.status.in?(%w[paid failed cancelled])

        Finance::PayoutAllocation.where(payout_id: payout.id, status: "reserved").lock.find_each do |allocation|
          allocation.update!(status: "released", released_at: at, consumed_at: nil)
        end
        payout.update!(status:, failure_code: failure_code, paid_at: nil)
        payout
      end
    end

    def validate_payout_total!(payout, allocations)
      total = allocations.sum(&:amount_minor)
      return if total == payout.amount_minor

      raise ActiveRecord::RecordInvalid.new(payout), I18n.t("finance.errors.payout_scope_mismatch")
    end

    def create_payout_ledger_entry!(payout, at:)
      Finance::LedgerEntry.find_by(idempotency_key: "finance-payout-#{payout.id}") ||
        Finance::LedgerEntry.create!(
          organization_id: payout.organization_id,
          type: "payout",
          amount_minor: -payout.amount_minor,
          currency: payout.currency,
          available_at: at,
          idempotency_key: "finance-payout-#{payout.id}",
          description: I18n.t("finance.ledger.descriptions.payout"),
          created_at: at
        )
    end
  end
end
