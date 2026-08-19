# frozen_string_literal: true

module Reconciliation
  # Rechecks payment attempts whose settlement grace has expired. The Orders
  # command rechecks the payment and order locks before accepting or releasing
  # anything, so overlapping workers cannot make a stale decision win.
  class PaymentAttemptsJob < ApplicationJob
    include Reconciliation::Support

    queue_as :payments
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    BATCH_SIZE = 100

    def perform(limit = BATCH_SIZE, now: Time.current)
      batch_id = SecureRandom.uuid
      batch_limit = bounded_limit(limit, BATCH_SIZE)
      payment_ids = claim_payment_ids(batch_limit, now)
      payment_ids.each { |payment_id| reconcile_payment(payment_id, batch_id:, now:) }
      schedule_remaining(candidate_scope(now), batch_limit)
    end

    private

    def candidate_scope(now)
      Orders::Payment
        .where(status: "processing")
        .where("settlement_grace_expires_at <= ?", now)
    end

    def claim_payment_ids(limit, now)
      Orders::Payment.transaction do
        candidate_scope(now)
          .order(:settlement_grace_expires_at, :id)
          .limit(limit)
          .lock("FOR UPDATE SKIP LOCKED")
          .pluck(:id)
      end
    end

    def reconcile_payment(payment_id, batch_id:, now:)
      payment = Orders::Payment.find(payment_id)
      before = payment.status
      result = Orders::ExpireSettlementGrace.call(payment_id:, now:)
      require_success!(result)
      payment = payment.reload
      audit_status_transition(
        payment,
        before:,
        after: payment.status,
        action: "reconciliation.payment_attempt.state_changed",
        batch_id:
      )
      instrument_outcome(
        "reconciliation.payment_attempt",
        record: payment,
        batch_id:,
        outcome: payment.status == "processing" ? "pending" : "resolved"
      ) { payment }
    rescue StandardError => error
      instrument_outcome(
        "reconciliation.payment_attempt",
        record: payment || Orders::Payment.find(payment_id),
        batch_id:,
        outcome: "error",
        code: error.class.name
      ) { raise }
    end
  end
end
