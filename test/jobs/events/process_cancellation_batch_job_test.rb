# frozen_string_literal: true

require "test_helper"

module Events
  class ProcessCancellationBatchJobTest < ActiveJob::TestCase
    include Events::CancellationTestHelpers

    class RefundAdapter < Payments::Providers::Adapter
      attr_accessor :available_minor, :refund_result
      attr_reader :refund_requests

      def initialize
        @available_minor = 10_000
        @refund_result = Payments::Providers::Result.success(provider_reference: "cancellation-refund")
        @refund_requests = []
      end

      def refund(**request)
        refund_requests << request
        refund_result
      end

      def verify_refund(**)
        refund_result
      end

      def available_balance(**)
        { amount_minor: available_minor, currency: "ETB" }
      end

      def capabilities
        { refunds: { supported: true, partial: true, fee_estimate_minor: 0 } }
      end
    end

    setup do
      @event = events_events(:ready_listing)
      @actor = core_users(:core_admin)
      @adapter = RefundAdapter.new
      Payments::Providers::Registry.register("chapa", @adapter)
      _order, @item, @payment = create_cancellation_order
      @cancellation = Events::Cancellation::Initiate.call(
        event: @event,
        actor: @actor,
        attendee_reason: "The event will not proceed.",
        idempotency_key: "job-cancellation-#{SecureRandom.hex(5)}"
      ).value
      Events::Cancellation::PrepareBatch.call(cancellation: @cancellation)
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
    end

    test "resolves a payment and completes the cancellation" do
      ProcessCancellationBatchJob.perform_now(@cancellation.id)

      refund = Orders::Refund.find_by!(event_cancellation: @cancellation)
      assert_equal "succeeded", refund.status
      assert_equal 1, @adapter.refund_requests.length
      assert_equal "resolved", Events::EventCancellationPayment.find_by!(
        event_cancellation: @cancellation,
        payment: @payment
      ).status
      assert_equal "completed", @cancellation.reload.status
      assert_equal 1, @cancellation.resolved_payments_count
    end

    test "marks insufficient funds as partially failed without reducing entitlement" do
      @adapter.available_minor = 0

      ProcessCancellationBatchJob.perform_now(@cancellation.id)

      refund = Orders::Refund.find_by!(event_cancellation: @cancellation)
      assert_equal "pending_funds", refund.status
      assert_equal @item.total_minor, refund.amount_minor
      snapshot = Events::EventCancellationPayment.find_by!(
        event_cancellation: @cancellation,
        payment: @payment
      )
      assert_equal "pending", snapshot.status
      assert_equal "partially_failed", @cancellation.reload.status
      assert_equal 1, @cancellation.failed_payments_count
      assert_empty @adapter.refund_requests
    end

    test "retries the same pending-funds refund after liquidity returns" do
      @adapter.available_minor = 0
      ProcessCancellationBatchJob.perform_now(@cancellation.id)
      refund = Orders::Refund.find_by!(event_cancellation: @cancellation)
      refund.update!(next_retry_at: 1.minute.ago)
      @adapter.available_minor = 10_000

      ProcessCancellationBatchJob.perform_now(@cancellation.id)

      assert_equal "succeeded", refund.reload.status
      assert_equal 1, Orders::Refund.where(event_cancellation: @cancellation).count
      assert_equal "resolved", Events::EventCancellationPayment.find_by!(
        event_cancellation: @cancellation,
        payment: @payment
      ).status
      assert_equal "completed", @cancellation.reload.status
      assert_equal 1, @adapter.refund_requests.length
    end

    test "a provider failure remains visible as a partial failure" do
      @adapter.refund_result = Payments::Providers::Result.failure(
        provider_reference: "cancellation-refund",
        failure_code: "declined"
      )

      ProcessCancellationBatchJob.perform_now(@cancellation.id)

      assert_equal "failed", Orders::Refund.find_by!(event_cancellation: @cancellation).status
      assert_equal "failed", Events::EventCancellationPayment.find_by!(
        event_cancellation: @cancellation,
        payment: @payment
      ).status
      assert_equal "partially_failed", @cancellation.reload.status
    end

    test "reconciles an ambiguous provider result without resubmitting the refund" do
      @adapter.refund_result = Payments::Providers::Result.unknown(raw_status: "pending")

      ProcessCancellationBatchJob.perform_now(@cancellation.id)

      refund = Orders::Refund.find_by!(event_cancellation: @cancellation)
      assert_equal "processing", refund.status
      snapshot = Events::EventCancellationPayment.find_by!(event_cancellation: @cancellation, payment: @payment)
      assert_equal "processing", snapshot.status
      assert_equal "processing", @cancellation.reload.status
      assert_equal 1, @adapter.refund_requests.length

      refund.update!(next_retry_at: 1.minute.ago)
      @adapter.refund_result = Payments::Providers::Result.success(provider_reference: "verified-refund")

      ProcessCancellationBatchJob.perform_now(@cancellation.id)

      assert_equal "succeeded", refund.reload.status
      assert_equal "completed", @cancellation.reload.status
      assert_equal 1, @adapter.refund_requests.length
    end

    test "retries safely after a worker crash following provider acceptance" do
      original_apply = Orders::ApplyRefundResult.method(:call)
      Orders::ApplyRefundResult.define_singleton_method(:call) do |**|
        raise "worker crashed after provider response"
      end

      assert_raises(RuntimeError) do
        Events::Cancellation::ProcessPayment.call(cancellation: @cancellation, now: Time.current)
      end
    ensure
      Orders::ApplyRefundResult.define_singleton_method(:call, original_apply)

      snapshot = Events::EventCancellationPayment.find_by!(event_cancellation: @cancellation, payment: @payment)
      refund = Orders::Refund.find_by!(event_cancellation: @cancellation)
      assert_equal "processing", snapshot.status
      assert_equal "processing", refund.status
      assert_equal 1, @adapter.refund_requests.length

      snapshot.update!(next_retry_at: 1.minute.ago)
      ProcessCancellationBatchJob.perform_now(@cancellation.id)

      assert_equal "succeeded", refund.reload.status
      assert_equal "resolved", snapshot.reload.status
      assert_equal "completed", @cancellation.reload.status
      assert_equal 1, @adapter.refund_requests.length
    end
  end
end
