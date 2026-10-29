# frozen_string_literal: true

module Messaging
  # Repairs accepted billing payments whose credit-grant outbox work was lost
  # or delayed. The bounded cursor keeps the sweep resumable; late payments for
  # failed top-ups create the normal provider-reversal obligation before the
  # Messaging ledger is resolved.
  class ReconcileCreditTopUpsJob < ApplicationJob
    queue_as :default

    BATCH_SIZE = 100

    def perform(cursor: nil, limit: BATCH_SIZE)
      failures = []
      batch_limit = [ limit.to_i, BATCH_SIZE ].min
      reconcile_unaccepted_succeeded_payments(failures, limit: batch_limit)

      # A top-up is eligible only when accepted payment evidence exists but the
      # immutable grant entry is absent (or a paid row is missing its entry).
      granted_ids = CreditLedgerEntry.where(
        entry_type: "top_up", reference_type: "Messaging::CreditTopUp"
      ).where.not(reference_id: nil).select(:reference_id)
      missing_grant = CreditTopUp.where.not(id: granted_ids)
      accepted_payment_top_ups = CreditTopUp.joins(billing_purchase: :payments)
        .where.not(orders_payments: { accepted_at: nil })
      scope = CreditTopUp.where(id: missing_grant.select(:id))
        .where(id: accepted_payment_top_ups.select(:id))
        .or(CreditTopUp.where(status: "paid").where.not(id: granted_ids)).order(:id)
      scope = scope.where("id > ?", cursor) if cursor.present?
      rows = scope.limit(batch_limit)
        .includes(:accepted_payment, billing_purchase: :payments).to_a
      rows.each do |top_up|
        payment = top_up.accepted_payment || top_up.billing_purchase&.payments&.find(&:accepted?)
        unless payment
          failures << [ top_up.id, "top_up_payment_mismatch" ]
          next
        end

        if top_up.status.in?(%w[failed cancelled])
          reversal = Orders::CreatePaymentReversal.call(payment:, reason_code: "late_payment")
          if reversal.failure?
            failures << [ top_up.id, reversal.error.code ]
            next
          end
          result = ResolveTopUpPayment.call(top_up:, payment:, outcome: "reversed")
        else
          result = GrantTopUpCredits.call(top_up:, payment:)
        end
        failures << [ top_up.id, result.error.code ] if result.failure?
      end
      Rails.logger.warn("messaging credit top-up reconciliation failures=#{failures.inspect}") if failures.any?
      self.class.perform_later(cursor: rows.last.id) if rows.length == batch_limit && rows.last
    end

    private

    def reconcile_unaccepted_succeeded_payments(failures, limit:)
      unaccepted = Orders::Payment.where.not(billing_purchase_id: nil)
        .where(status: "succeeded", accepted_at: nil)
        .where.not(id: Orders::Refund.where(type: "payment_reversal").select(:payment_id))
        .order(:id)
        .limit(limit)

      unaccepted.each do |payment|
        result = Orders::AcceptBillingPayment.call(payment:)
        failures << [ payment.id, result.error.code ] if result.failure?
      end
    end
  end
end
