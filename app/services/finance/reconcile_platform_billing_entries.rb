# frozen_string_literal: true

module Finance
  # Repairs missing platform journal rows from authoritative payment/refund facts.
  class ReconcilePlatformBillingEntries < Core::BaseService
    DEFAULT_LIMIT = 100
    MAX_LIMIT = 500
    Result = Data.define(:charges_reconciled, :refunds_reconciled)

    def initialize(limit: DEFAULT_LIMIT)
      @limit = [ [ limit.to_i, 1 ].max, MAX_LIMIT ].min
    end

    def call
      charges = reconcile_charges
      refunds = reconcile_refunds(remaining_limit(charges))
      success(Result.new(charges, refunds))
    rescue Core::Error => exception
      failure(exception)
    end

    private

    attr_reader :limit

    def reconcile_charges
      purchase_ids = Orders::BillingPurchase.where(
        source_type: "Marketing::FeaturedPlacement", status: "paid"
      ).select(:id)
      payment_scope = Orders::Payment.where(billing_purchase_id: purchase_ids, status: "succeeded")
        .where.not(accepted_at: nil)
        .includes(:billing_purchase)
        .where(<<~SQL.squish)
          NOT EXISTS (
            SELECT 1 FROM finance_platform_billing_entries AS charge_entries
             WHERE charge_entries.payment_id = orders_payments.id
               AND charge_entries.type = 'featured_placement_charge'
          ) OR (orders_payments.provider_fee_minor > 0 AND NOT EXISTS (
            SELECT 1 FROM finance_platform_billing_entries AS fee_entries
             WHERE fee_entries.payment_id = orders_payments.id
               AND fee_entries.type = 'provider_fee'
          ))
        SQL
      payments = payment_scope.order(:id).limit(limit).to_a
      payments.each do |payment|
        result = PostPlatformBillingEntry.call(payment:, billing_purchase: payment.billing_purchase, type: :charge)
        raise result.error if result.failure?
      end
      payments.length
    end

    def reconcile_refunds(remaining)
      return 0 unless remaining.positive?

      refunds = Orders::Refund.where(
        type: "billing_purchase_refund", status: "succeeded"
      ).where.not(billing_purchase_id: nil)
        .where.not(id: Finance::PlatformBillingEntry.where(type: "featured_placement_refund").select(:refund_id))
        .includes(:payment, :billing_purchase)
        .order(:id).limit(remaining)
      pending_refunds = refunds.to_a
      pending_refunds.each do |refund|
        result = PostPlatformBillingEntry.call(
          payment: refund.payment, billing_purchase: refund.billing_purchase, refund:, type: :refund
        )
        raise result.error if result.failure?
      end
      pending_refunds.length
    end

    def remaining_limit(charges)
      [ limit - charges, 0 ].max
    end
  end
end
