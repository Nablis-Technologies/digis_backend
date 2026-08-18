# frozen_string_literal: true

module Commercial
  module Subsidies
    # Reserves one positive amount from a hard subsidy budget for an active
    # checkout order. The budget row is locked before replay and capacity
    # checks, so two last-unit holds cannot both pass.
    class Hold < Core::BaseService
      include Support

      ACTIVE_ORDER_STATUSES = %w[draft pending_payment].freeze

      def initialize(budget:, order:, amount_minor:, currency:, expires_at:, idempotency_key:)
        @budget = budget
        @order = order
        @amount_minor = amount_minor
        @currency = currency
        @expires_at = expires_at
        @idempotency_key = idempotency_key
      end

      def call
        prepare_request!
        ActiveRecord::Base.transaction { hold_locked }
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(invalid_record_error(error))
      rescue ActiveRecord::RecordNotFound
        failure(subsidy_error("record_not_found", code: "subsidy_record_not_found"))
      rescue ActiveRecord::RecordNotUnique
        failure(subsidy_error("idempotency_conflict", code: "idempotency_conflict"))
      rescue ArgumentError, TypeError
        failure(invalid_idempotency_error)
      end

      private

      attr_reader :budget, :order, :amount_minor, :currency, :expires_at,
                  :idempotency_key, :key_digest, :request_fingerprint

      def prepare_request!
        @idempotency_key = normalize_idempotency_key(idempotency_key)
        @key_digest = idempotency_digest("subsidy-hold", idempotency_key)
        @amount_minor = Integer(amount_minor)
        @currency = currency.to_s.strip.upcase.presence
        @expires_at = expires_at&.to_time
        @request_fingerprint = fingerprint_for(
          action: "hold",
          subsidy_budget_id: budget.id,
          order_id: order.id,
          amount_minor:,
          currency:,
          expires_at:
        )
      end

      def hold_locked
        locked_budget = Commercial::SubsidyBudget.lock.find(budget.id)
        existing = Commercial::SubsidyReservation.lock.find_by(idempotency_key_digest: key_digest)
        return replay_result(existing) if existing

        active = Commercial::SubsidyReservation.lock
          .where(subsidy_budget_id: locked_budget.id, order_id: order.id)
          .where(status: Commercial::SubsidyReservation::ACTIVE_STATUSES)
          .first
        return failure(subsidy_error("reservation_exists", code: "subsidy_reservation_exists")) if active

        locked_order = Orders::Order.lock.find(order.id)
        validation = validate_request(locked_budget, locked_order)
        return validation if validation

        return failure(subsidy_error("budget_exhausted", code: "subsidy_budget_exhausted")) if
          locked_budget.remaining_minor < amount_minor

        reservation = Commercial::SubsidyReservation.create!(
          subsidy_budget: locked_budget,
          order: locked_order,
          idempotency_key_digest: key_digest,
          request_fingerprint:,
          amount_minor:,
          currency:,
          status: "held",
          expires_at:
        )
        locked_budget.update!(reserved_minor: locked_budget.reserved_minor + amount_minor)
        record_subsidy_transition!(
          reservation:,
          from: nil,
          to: "held",
          action: "commercial.subsidy_reservation.held",
          audit_key: "commercial-subsidy-hold-#{key_digest}",
          timestamp_attribute: :created_at
        )
        success(reservation)
      end

      def validate_request(locked_budget, locked_order)
        return failure(subsidy_error("amount_invalid", code: "subsidy_amount_invalid")) unless amount_minor.positive?
        return failure(subsidy_error("currency_required", code: "subsidy_currency_required")) if currency.blank?
        return failure(subsidy_error("expiry_invalid", code: "subsidy_expiry_invalid")) unless expires_at > Time.current
        return failure(subsidy_error("order_not_active", code: "subsidy_order_not_active")) unless
          locked_order.status.in?(ACTIVE_ORDER_STATUSES)
        return failure(subsidy_error("hold_currency_mismatch", code: "subsidy_currency_mismatch")) unless
          locked_budget.currency == currency && locked_order.charge_currency == currency

        nil
      end

      def replay_result(existing)
        return success(existing) if existing.request_fingerprint == request_fingerprint

        failure(subsidy_error("idempotency_conflict", code: "idempotency_conflict"))
      end
    end
  end
end
