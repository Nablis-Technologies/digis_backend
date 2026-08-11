# frozen_string_literal: true

module Commercial
  module Subsidies
    # Reclaims timed-out held/processing subsidy capacity in deterministic
    # budget/reservation order. Each row is rechecked after locking so a payment
    # transition that wins the race is never released by the expiry sweep.
    class ExpireHolds < Core::BaseService
      include Support

      BATCH_SIZE = 100

      def initialize(now: Time.current)
        @now = now
      end

      def call
        expired_ids.each_slice(BATCH_SIZE).sum { |reservation_ids| expire_batch(reservation_ids) }
          .then { |count| success(count) }
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(invalid_record_error(error))
      rescue ActiveRecord::RecordNotFound
        failure(subsidy_error("record_not_found", code: "subsidy_record_not_found"))
      end

      private

      attr_reader :now

      def expired_ids
        Commercial::SubsidyReservation
          .active
          .where("expires_at <= ?", now)
          .order(:subsidy_budget_id, :id)
          .pluck(:id)
      end

      def expire_batch(reservation_ids)
        ActiveRecord::Base.transaction do
          candidates = Commercial::SubsidyReservation.where(id: reservation_ids)
            .order(:subsidy_budget_id, :id).to_a
          next 0 if candidates.empty?

          budget_ids = candidates.map(&:subsidy_budget_id).uniq.sort
          budgets = Commercial::SubsidyBudget.where(id: budget_ids).order(:id).lock.to_a.index_by(&:id)
          reservations = Commercial::SubsidyReservation.where(id: reservation_ids)
            .order(:subsidy_budget_id, :id).lock.to_a
          orders = Orders::Order.where(id: reservations.map(&:order_id).uniq).to_a.index_by(&:id)
          reservations.each do |reservation|
            reservation.association(:subsidy_budget).target = budgets.fetch(reservation.subsidy_budget_id)
            reservation.association(:order).target = orders.fetch(reservation.order_id)
          end

          expiring = reservations.select { |reservation| reservation.active? && reservation.expires_at <= now }
          next 0 if expiring.empty?

          expiring.group_by(&:subsidy_budget_id).each do |budget_id, rows|
            budget = budgets.fetch(budget_id)
            amount = rows.sum(&:amount_minor)
            raise counter_drift if budget.reserved_minor < amount

            budget.update!(reserved_minor: budget.reserved_minor - amount)
          end

          expiring.sum do |reservation|
            from = reservation.status
            reservation.update!(status: "released", released_at: now)
            record_subsidy_transition!(
              reservation:,
              from:,
              to: "released",
              action: "commercial.subsidy_reservation.released",
              audit_key: reservation_transition_audit_key(reservation, "released"),
              reason: "expired",
              timestamp_attribute: :released_at
            )
            1
          end
        end
      end

      def counter_drift
        subsidy_error("counter_drift", code: "subsidy_budget_counter_drift")
      end
    end
  end
end
