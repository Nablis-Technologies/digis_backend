# frozen_string_literal: true

module Reconciliation
  # Resumes due refund obligations. Processing rows use provider verification;
  # created and liquidity-blocked rows use the normal submission command. Both
  # commands lock the refund and reuse its durable idempotency key.
  class RefundsJob < ApplicationJob
    include Reconciliation::Support

    queue_as :payments
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    BATCH_SIZE = 100

    def perform(limit = BATCH_SIZE, now: Time.current)
      batch_id = SecureRandom.uuid
      batch_limit = bounded_limit(limit, BATCH_SIZE)
      refund_ids = claim_refund_ids(batch_limit, now)
      refund_ids.each { |refund_id| reconcile_refund(refund_id, batch_id:, now:) }
      schedule_remaining(candidate_scope(now), batch_limit)
    end

    private

    def candidate_scope(now)
      Orders::Refund.where(
        <<~SQL.squish,
          (status = 'processing' AND (next_retry_at IS NULL OR next_retry_at <= :now)) OR
          (status IN ('created', 'pending_funds') AND
            (next_retry_at IS NULL OR next_retry_at <= :now))
        SQL
        now:
      )
    end

    def claim_refund_ids(limit, now)
      Orders::Refund.transaction do
        candidate_scope(now)
          .order(Arel.sql("next_retry_at ASC NULLS FIRST"), :id)
          .limit(limit)
          .lock("FOR UPDATE SKIP LOCKED")
          .pluck(:id)
      end
    end

    def reconcile_refund(refund_id, batch_id:, now:)
      refund = Orders::Refund.find(refund_id)
      before = refund.status
      result = if before == "processing"
        Orders::ReconcileRefund.call(refund:, now:)
      else
        Orders::SubmitRefund.call(refund:, now:)
      end
      require_success!(result)
      refund = refund.reload
      audit_status_transition(
        refund,
        before:,
        after: refund.status,
        action: "reconciliation.refund.state_changed",
        batch_id:
      )
      instrument_outcome(
        "reconciliation.refund",
        record: refund,
        batch_id:,
        outcome: refund.status == "processing" ? "pending" : "resolved"
      ) { refund }
    rescue StandardError => error
      instrument_outcome(
        "reconciliation.refund",
        record: refund || Orders::Refund.find(refund_id),
        batch_id:,
        outcome: "error",
        code: error.class.name
      ) { raise }
    end
  end
end
