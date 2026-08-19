# frozen_string_literal: true

module Reconciliation
  # Verifies organizer payouts left in provider-processing state. Finance owns
  # the payout lock, reserve/accounting transition, and unknown-result policy.
  class OrganizerPayoutsJob < ApplicationJob
    include Reconciliation::Support

    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    BATCH_SIZE = 100

    def perform(limit = BATCH_SIZE, now: Time.current)
      batch_id = SecureRandom.uuid
      batch_limit = bounded_limit(limit, BATCH_SIZE)
      payout_ids = claim_payout_ids(batch_limit)
      payout_ids.each { |payout_id| reconcile_payout(payout_id, batch_id:, now:) }
      schedule_remaining(candidate_scope, batch_limit)
    end

    private

    def candidate_scope
      Finance::Payout.where(status: "processing")
    end

    def claim_payout_ids(limit)
      Finance::Payout.transaction do
        candidate_scope.order(:requested_at, :id).limit(limit)
          .lock("FOR UPDATE SKIP LOCKED").pluck(:id)
      end
    end

    def reconcile_payout(payout_id, batch_id:, now:)
      payout = Finance::Payout.find(payout_id)
      before = payout.status
      adapter = Finance::PayoutProviders::Registry.fetch(payout.provider)
      result = Finance::ReconcilePayout.call(payout:, adapter:, at: now)
      require_success!(result)
      payout = payout.reload
      audit_status_transition(
        payout,
        before:,
        after: payout.status,
        action: "reconciliation.organizer_payout.state_changed",
        batch_id:
      )
      instrument_outcome(
        "reconciliation.organizer_payout",
        record: payout,
        batch_id:,
        outcome: payout.status == "processing" ? "pending" : "resolved"
      ) { payout }
    rescue StandardError => error
      instrument_outcome(
        "reconciliation.organizer_payout",
        record: payout || Finance::Payout.find(payout_id),
        batch_id:,
        outcome: "error",
        code: error.class.name
      ) { raise }
    end
  end
end
