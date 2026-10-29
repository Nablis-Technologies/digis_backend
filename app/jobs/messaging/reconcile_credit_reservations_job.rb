# frozen_string_literal: true

module Messaging
  # Releases reservations that have been stuck beyond the delivery retry
  # window. Each row uses a deterministic command key, so rerunning the sweep
  # cannot append a second release/expiry ledger entry.
  class ReconcileCreditReservationsJob < ApplicationJob
    queue_as :default

    BATCH_SIZE = 100
    EXPIRY = 24.hours

    def perform(cursor: nil, limit: BATCH_SIZE, now: Time.current)
      failures = []
      scope = CreditReservation.where(status: "reserved").where("reserved_at < ?", now - EXPIRY).order(:id)
      scope = scope.where("id > ?", cursor) if cursor.present?
      rows = scope.limit([ limit.to_i, BATCH_SIZE ].min).to_a
      rows.each do |reservation|
        result = CreditAccounts::Expire.call(
          reservation:, idempotency_key: "reconcile-credit-reservation-#{reservation.id}", at: now
        )
        failures << [ reservation.id, result.error.code ] if result.failure?
      end
      Rails.logger.warn("messaging credit reservation reconciliation failures=#{failures.inspect}") if failures.any?
      self.class.perform_later(cursor: rows.last.id) if rows.length == [ limit.to_i, BATCH_SIZE ].min && rows.last
    end
  end
end
