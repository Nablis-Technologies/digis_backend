# frozen_string_literal: true

require "test_helper"

module Orders
  class WebhookIngestionPerformanceTest < ActionDispatch::IntegrationTest
    BATCH_SIZE = 500
    MAX_SECONDS = 20.0

    setup do
      skip "set EVENT_PLATFORM_PERFORMANCE=1 to run throughput benchmarks" unless
        ENV["EVENT_PLATFORM_PERFORMANCE"] == "1"

      @adapter = Payments::Providers::FakePaymentProvider.new
      Payments::Providers::Registry.register("chapa", @adapter)
    end

    teardown do
      Payments::Providers::Registry.instance_variable_set(:@adapters, {})
    end

    test "ingests an out-of-order webhook batch and deduplicates retries" do
      payloads = Array.new(BATCH_SIZE) do |index|
        {
          event_id: "performance-webhook-#{index}",
          type: "payment.succeeded",
          status: "paid",
          occurred_at: Time.current.iso8601
        }
      end
      started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      without_n_plus_one do
        payloads.reverse_each { |payload| post_webhook(payload) }
        payloads.first(20).each { |payload| post_webhook(payload) }
      end

      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
      assert_equal BATCH_SIZE, Orders::PaymentEvent.where(provider: "chapa").count
      assert_equal BATCH_SIZE, Core::OutboxEvent.where(event_type: "orders.payment_event.received").count
      assert_operator elapsed, :<, MAX_SECONDS, "webhook batch took #{elapsed.round(2)} seconds"
    end

    private

    def without_n_plus_one
      defined?(Prosopite) ? Prosopite.pause { yield } : yield
    end

    def post_webhook(payload)
      post "/payments/chapa/webhook",
           params: payload,
           headers: { "X-Provider-Signature" => "performance-signature" },
           as: :json
      assert_response :accepted
    end
  end
end
