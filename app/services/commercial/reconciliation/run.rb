# frozen_string_literal: true

module Commercial
  module Reconciliation
    # Compares immutable checkout, subsidy, volume, provider, ledger, and
    # payout evidence. It may repair only the documented prospective volume
    # cache; paid orders, accepted usage, terminal reservations, ledger rows,
    # and payout allocations remain append-only facts.
    class Run < Core::BaseService
      GRANDFATHER_ALERT_WINDOW = 7.days
      FEE_TYPES = %w[service_fee platform_fee processing_fee resale_platform_fee].freeze
      LEDGER_EXCLUDED_TYPES = %w[refund chargeback payout].freeze

      def initialize(at: Time.current)
        @at = at.to_time.utc
        @mismatches = []
        @checked = Hash.new(0)
      end

      def call
        reconcile_orders
        reconcile_subsidies
        reconcile_volume
        reconcile_payouts
        reconcile_grandfather_periods

        success(
          checked: checked,
          mismatches: mismatches,
          alerts_evaluated: alerts_evaluated
        )
      rescue Core::Error => error
        failure(error)
      end

      private

      attr_reader :at, :mismatches, :checked

      def reconcile_orders
        Orders::Order.where(status: Orders::Order::PAID_STATUSES)
          .includes(:order_adjustments, :payments, :finance_ledger_entries, :subsidy_reservations)
          .find_each do |order|
          checked[:orders] += 1
          reconcile_order_adjustments(order)
          reconcile_subsidy_usage(order)
          reconcile_provider_cost(order)
          reconcile_order_ledger(order)
        end
      end

      def reconcile_order_adjustments(order)
        adjustments = order.order_adjustments.to_a
        expected = {
          "discount_minor" => -adjustments.sum { |adjustment| adjustment.type == "discount" ? adjustment.amount_minor : 0 },
          "subsidy_minor" => -adjustments.sum { |adjustment| adjustment.type == "subsidy" ? adjustment.amount_minor : 0 },
          "fee_minor" => adjustments.sum { |adjustment| FEE_TYPES.include?(adjustment.type) ? adjustment.amount_minor : 0 },
          "tax_minor" => adjustments.sum { |adjustment| adjustment.type == "tax" ? adjustment.amount_minor : 0 },
          "adjustment_minor" => adjustments.sum { |adjustment| adjustment.type == "manual_adjustment" ? adjustment.amount_minor : 0 }
        }
        expected["total_minor"] = order.subtotal_minor - expected.fetch("discount_minor") -
          expected.fetch("subsidy_minor") + expected.fetch("fee_minor") + expected.fetch("tax_minor") +
          expected.fetch("adjustment_minor")
        actual = expected.keys.index_with { |attribute| order.public_send(attribute) }
        return if expected == actual

        add_mismatch(
          kind: "order_adjustment_mismatch",
          aggregate: order,
          details: { expected:, actual: }
        )
      end

      def reconcile_subsidy_usage(order)
        expected = order.subsidy_reservations.to_a
          .select(&:committed?)
          .sum(&:amount_minor)
        return if expected == order.subsidy_minor
        return if expected.zero? && order.subsidy_minor.zero?

        checked[:subsidy_usages] += 1
        add_mismatch(
          kind: "subsidy_usage_mismatch",
          aggregate: order,
          details: {
            expected_committed_minor: expected,
            actual_order_subsidy_minor: order.subsidy_minor,
            reservation_ids: order.subsidy_reservations.map(&:id)
          }
        )
      end

      def reconcile_provider_cost(order)
        # Checkout records the provider-cost projection as a processing-fee
        # adjustment; the accepted provider callback supplies the actual cost.
        projected = order.order_adjustments.to_a
          .select { |adjustment| adjustment.type == "processing_fee" }
          .sum(&:amount_minor)
        order.payments.select(&:accepted?).each do |payment|
          next if payment.provider_fee_minor.nil?

          checked[:payments] += 1
          actual = payment.provider_fee_minor
          next if actual == projected && payment.provider_fee_currency == payment.currency

          details = {
            payment_id: payment.id,
            projected_provider_fee_minor: projected,
            actual_provider_fee_minor: actual,
            provider_fee_currency: payment.provider_fee_currency,
            payment_currency: payment.currency
          }
          add_mismatch(kind: "provider_projection_mismatch", aggregate: payment, details:)
          add_mismatch(
            kind: "margin_variance",
            aggregate: payment,
            details: details.merge(variance_minor: actual - projected)
          ) if actual > projected
        end
      end

      def reconcile_order_ledger(order)
        # Refunds, chargebacks, and payout allocations have separate
        # append-only reconciliation boundaries and must not be folded into
        # the original accepted-order settlement comparison.
        payment_ids = order.payments.select(&:accepted?).map(&:id)
        return if payment_ids.empty?

        entries = order.finance_ledger_entries.to_a.select do |entry|
          entry.payment_id.in?(payment_ids) && !LEDGER_EXCLUDED_TYPES.include?(entry.type)
        end
        return if entries.empty?

        checked[:ledger_entries] += entries.length
        actual = entries.sum(&:amount_minor)
        return if actual == order.settlement_total_minor

        add_mismatch(
          kind: "ledger_mismatch",
          aggregate: order,
          details: {
            expected_settlement_minor: order.settlement_total_minor,
            actual_ledger_minor: actual,
            ledger_entry_ids: entries.map(&:id)
          }
        )
      end

      def reconcile_subsidies
        Commercial::SubsidyBudget.includes(:subsidy_reservations).find_each do |budget|
          checked[:subsidy_budgets] += 1
          reservations = budget.subsidy_reservations.to_a
          expected_reserved = reservations.sum { |reservation| reservation.active? ? reservation.amount_minor : 0 }
          expected_consumed = reservations.sum { |reservation| reservation.committed? ? reservation.amount_minor : 0 }
          if budget.reserved_minor != expected_reserved || budget.consumed_minor != expected_consumed
            add_mismatch(
              kind: "subsidy_budget_mismatch",
              aggregate: budget,
              details: {
                expected_reserved_minor: expected_reserved,
                actual_reserved_minor: budget.reserved_minor,
                expected_consumed_minor: expected_consumed,
                actual_consumed_minor: budget.consumed_minor
              }
            )
          end
          next unless budget.reserved_minor + budget.consumed_minor >= budget.limit_minor

          publish_alert(
            kind: "budget_exhausted",
            aggregate: budget,
            details: {
              limit_minor: budget.limit_minor,
              reserved_minor: budget.reserved_minor,
              consumed_minor: budget.consumed_minor,
              currency: budget.currency
            }
          )
        end
      end

      def reconcile_volume
        Commercial::VolumeCounter.find_each do |counter|
          checked[:volume_counters] += 1
          expected = Commercial::VolumeUsage.for_dimension(counter.attributes.symbolize_keys).sum(:value)
          next if counter.value == expected

          mismatch = add_mismatch(
            kind: "volume_counter_drift",
            aggregate: counter,
            details: { expected_value: expected, actual_value: counter.value }
          )
          result = Commercial::Volume::Reconcile.call(counter:)
          raise result.error if result.failure?

          publish_alert(
            kind: "volume_counter_drift",
            aggregate: counter,
            details: mismatch.fetch(:details).merge(corrected_value: counter.reload.value)
          )
        end
      end

      def reconcile_payouts
        Finance::Payout.includes(:allocations).find_each do |payout|
          checked[:payouts] += 1
          actual = payout.allocations.sum(&:amount_minor)
          next if actual == payout.amount_minor

          add_mismatch(
            kind: "payout_allocation_mismatch",
            aggregate: payout,
            details: {
              expected_amount_minor: payout.amount_minor,
              actual_allocated_minor: actual,
              allocation_ids: payout.allocations.map(&:id)
            }
          )
        end
      end

      def reconcile_grandfather_periods
        FeeScheduleVersion.where(status: %w[scheduled active]).where.not(grandfather_until: nil).find_each do |version|
          next unless version.grandfather_until <= at + GRANDFATHER_ALERT_WINDOW

          kind = version.grandfather_until > at ? "grandfather_expiring" : "grandfather_expired"
          publish_alert(
            kind:,
            aggregate: version,
            details: {
              fee_schedule_version_id: version.id,
              grandfather_until: version.grandfather_until.iso8601(6),
              acceptance_policy: version.acceptance_policy
            }
          )
        end
      end

      def add_mismatch(kind:, aggregate:, details:)
        row = {
          kind:,
          aggregate_type: aggregate.class.base_class.name,
          aggregate_id: aggregate.id,
          details: details.deep_stringify_keys
        }
        mismatches << row
        publish_alert(kind:, aggregate:, details: row.fetch(:details))
        row
      end

      def publish_alert(kind:, aggregate:, details:)
        result = Commercial::Alerts::Publish.call(kind:, aggregate:, details:)
        raise result.error if result.failure?

        @alerts_evaluated = alerts_evaluated + 1
        result.value
      end

      def alerts_evaluated
        @alerts_evaluated ||= 0
      end
    end
  end
end
