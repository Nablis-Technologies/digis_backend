# frozen_string_literal: true

require "test_helper"

module Commercial
  module Reconciliation
    class RunTest < ActiveSupport::TestCase
      include Commercial::FeeDefinitionTestHelpers
      include Commercial::VolumeTestHelpers

      setup do
        setup_volume_context
        @order = create_volume_order(status: "draft")
        @counter = Commercial::VolumeCounter.create!(
          fee_component: @component,
          organization: @organization,
          event: @event,
          metric_type: "accepted_paid_units",
          window_type: "event",
          window_start_at: @quoted_at - 1.day,
          window_end_at: @quoted_at + 1.day,
          value: 9,
          lock_version: 0
        )
        add_processing_adjustment(amount_minor: 100)
        @order.update_columns(fee_minor: 100, total_minor: 10_100, settlement_total_minor: 10_100)
        @order.update_columns(status: "paid", paid_at: @quoted_at)
        Commercial::VolumeUsage.create!(
          fee_component: @component,
          organization: @organization,
          event: @event,
          order: @order,
          metric_type: "accepted_paid_units",
          window_type: "event",
          window_start_at: @counter.window_start_at,
          window_end_at: @counter.window_end_at,
          value: 3,
          accepted_at: @quoted_at
        )
        @payment = Orders::Payment.create!(
          order: @order,
          attempt_number: 1,
          provider: "chapa",
          payment_method: "telebirr",
          status: "succeeded",
          amount_minor: 10_100,
          currency: "ETB",
          commercial_signature: @order.commercial_signature,
          buyer_fee_minor: 0,
          organizer_fee_minor: 100,
          provider_fee_minor: 150,
          provider_fee_currency: "ETB",
          idempotency_key: "task12-payment-#{SecureRandom.hex(4)}",
          provider_reference: "task12-provider-#{SecureRandom.hex(4)}",
          accepted_at: @quoted_at,
          succeeded_at: @quoted_at,
          settlement_grace_minutes: 5,
          settlement_grace_expires_at: @quoted_at + 5.minutes
        )
      end

      test "reports provider variance, repairs volume cache, and does not rewrite order evidence" do
        adjustment = @order.order_adjustments.sole
        snapshot = [ @order.reload.fee_minor, @order.total_minor, adjustment.amount_minor, @payment.reload.provider_fee_minor ]

        first = Commercial::Reconciliation::Run.call(at: @quoted_at + 1.hour)
        second = Commercial::Reconciliation::Run.call(at: @quoted_at + 1.hour)

        assert_predicate first, :success?, first.error&.message
        assert_predicate second, :success?, second.error&.message
        kinds = first.value.fetch(:mismatches).map { |row| row.fetch(:kind) }
        assert_includes kinds, "provider_projection_mismatch"
        assert_includes kinds, "margin_variance"
        assert_equal 3, @counter.reload.value
        assert_equal snapshot, [ @order.reload.fee_minor, @order.total_minor, adjustment.reload.amount_minor, @payment.reload.provider_fee_minor ]
        first_alert_count = Core::OutboxEvent.where(event_type: "commercial.operational_alert").count
        assert_operator first_alert_count, :>=, 3
        assert_equal first_alert_count, Core::OutboxEvent.where(event_type: "commercial.operational_alert").count
        assert_equal 1, Core::OutboxEvent.where(event_type: "commercial.volume_counter.reconciled").count
        assert_equal first.value.fetch(:mismatches).map { |row| row.fetch(:kind) }.grep(/provider|margin/),
          second.value.fetch(:mismatches).map { |row| row.fetch(:kind) }.grep(/provider|margin/)
      end

      private

      def add_processing_adjustment(amount_minor:)
        @order.order_adjustments.create!(
          type: "processing_fee",
          label: "Processing recovery",
          charged_to: "organizer",
          amount_minor:,
          currency: "ETB",
          refund_policy: "nonrefundable",
          calculation_type: "fixed",
          fixed_amount_minor: amount_minor,
          funded_by: "organizer",
          source_type: "Commercial::FeeComponent",
          source_id: @component.id,
          resolution_evidence: {}
        )
      end
    end
  end
end
