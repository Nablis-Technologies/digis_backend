# frozen_string_literal: true

require "test_helper"

module Orders
  class ReconcileRefundJobTest < ActiveJob::TestCase
    class RefundAdapter < Payments::Providers::Adapter
      attr_reader :refund_requests, :verify_requests
      attr_accessor :refund_result, :verify_result

      def initialize
        @refund_requests = []
        @verify_requests = []
        @refund_result = Payments::Providers::Result.success(provider_reference: "refund-ref")
        @verify_result = Payments::Providers::Result.success(provider_reference: "refund-ref")
      end

      def refund(**request)
        refund_requests << request
        refund_result
      end

      def verify_refund(**request)
        verify_requests << request
        verify_result
      end

      def available_balance(**)
        nil
      end

      def capabilities = {}
    end

    setup do
      @event = events_events(:ready_listing)
      @buyer = core_users(:attendee)
      Orders::Order.where(event: @event, buyer_user: @buyer).where(status: %w[draft pending_payment]).update_all(
        status: "cancelled", closed_reason: "test_cleanup"
      )
      @refund = create_refund
      @adapter = RefundAdapter.new
      Payments::Providers::Registry.register("chapa", @adapter)
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
    end

    test "verifies an in-flight refund without issuing a second provider request" do
      @refund.update!(status: "processing", provider_reference: "maybe-ref")

      ReconcileRefundJob.perform_now(@refund.id)

      assert_equal "succeeded", @refund.reload.status
      assert_equal "refund-ref", @refund.provider_reference
      assert_empty @adapter.refund_requests
      assert_equal @refund.idempotency_key, @adapter.verify_requests.sole.fetch(:idempotency_key)
    end

    test "retries a pending-funds refund after a top-up signal" do
      @refund.update!(status: "pending_funds", pending_reason: "insufficient_funds", next_retry_at: 1.minute.ago)

      RetryPendingFundsRefundJob.perform_now

      assert_equal "succeeded", @refund.reload.status
      assert_equal 1, @adapter.refund_requests.length
    end

    test "a submission crash leaves a processing refund for verification" do
      @adapter.define_singleton_method(:refund) do |**request|
        refund_requests << request
        raise "provider connection lost"
      end

      assert_nothing_raised do
        SubmitRefundJob.perform_now(@refund.id)
      end
      @refund.reload

      assert_equal "processing", @refund.status
      assert_equal 1, @adapter.refund_requests.length

      ReconcileRefundJob.perform_now(@refund.id)

      assert_equal "succeeded", @refund.reload.status
      assert_empty @adapter.refund_requests[1..]
    end

    test "a crash after the provider response leaves the obligation for verification" do
      original_call = Orders::ApplyRefundResult.method(:call)
      Orders::ApplyRefundResult.define_singleton_method(:call) do |**|
        raise "worker crashed after provider response"
      end

      assert_nothing_raised do
        SubmitRefundJob.perform_now(@refund.id)
      end
    ensure
      Orders::ApplyRefundResult.define_singleton_method(:call, original_call)
      assert_equal "processing", @refund.reload.status
      assert_equal 1, @adapter.refund_requests.length

      ReconcileRefundJob.perform_now(@refund.id)

      assert_equal "succeeded", @refund.reload.status
    end

    test "dispatches refund-created outbox delivery with only the refund ID" do
      outbox = Core::OutboxEvent.find_by!(event_type: "orders.refund.created", aggregate_id: @refund.payment_id)

      assert_enqueued_with(job: SubmitRefundJob, args: [ @refund.id ]) do
        Rails.application.config.x.outbox_handlers.fetch("orders.refund.created").call(outbox)
      end
    end

    private

    def create_refund
      order = Orders::Order.create!(
        event: @event, buyer_user: @buyer, sales_channel: "online", status: "draft",
        charge_currency: "ETB", commercial_signature: "a" * 64,
        subtotal_minor: 1_000, discount_minor: 0, subsidy_minor: 0, fee_minor: 0,
        tax_minor: 0, adjustment_minor: 0, total_minor: 1_000,
        settlement_currency: "ETB", settlement_total_minor: 1_000, exchange_rate: 1,
        exchange_rate_source: "same_currency", exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now, idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
      product = Catalog::EventProduct.create!(
        event: @event, name: "Refund reconcile product #{SecureRandom.hex(4)}",
        type: "merchandise", status: "active"
      )
      item = Orders::OrderItem.create!(
        order:, event_product: product, name_snapshot: product.name, type_snapshot: "merchandise",
        quantity: 1, base_currency: "ETB", base_unit_amount_minor: 1_000,
        charge_currency: "ETB", charge_unit_amount_minor: 1_000, exchange_rate: 1,
        discount_minor: 0, total_minor: 1_000, fulfillment_status: "fulfilled"
      )
      order.update!(status: "fulfilled", paid_at: Time.current)
      payment = Orders::Payment.create!(
        order:, attempt_number: 1, provider: "chapa", payment_method: "telebirr",
        status: "succeeded", amount_minor: 1_000, currency: "ETB",
        commercial_signature: order.commercial_signature, buyer_fee_minor: 0, organizer_fee_minor: 0,
        idempotency_key: "payment-#{SecureRandom.hex(6)}", provider_reference: "provider-#{SecureRandom.hex(4)}",
        accepted_at: Time.current, succeeded_at: Time.current,
        settlement_grace_minutes: 5, settlement_grace_expires_at: order.expires_at + 5.minutes
      )
      result = Orders::CreateItemRefund.call(
        payment:, order_item: item, quantity: 1, reason_code: "event_cancellation",
        idempotency_key: "reconcile-refund-#{SecureRandom.hex(6)}"
      )
      assert_predicate result, :success?, result.error&.message
      result.value
    end
  end
end
