# frozen_string_literal: true

require "test_helper"

module Messaging
  module Providers
    class TestAdapterTest < ActiveSupport::TestCase
      test "returns a configured campaign result and records safe call metadata" do
        expected = DeliveryResult.sent(provider: "test")
        adapter = TestAdapter.new(default: expected)
        delivery = Struct.new(:id, :channel).new("delivery-1", "sms")

        result = adapter.deliver_campaign(
          campaign: Object.new, delivery:, content: { body: "sensitive" }, idempotency_key: "digest"
        )

        assert_same expected, result
        assert_equal [ { delivery_id: "delivery-1", channel: "sms" } ], adapter.calls
      end

      test "resolves an outcome per delivery without retaining message content" do
        delivery = Struct.new(:id, :channel).new("delivery-2", "email")
        adapter = TestAdapter.new(
          outcomes: { delivery.id => DeliveryResult.failed(provider: "test", failure_code: "rejected") }
        )

        result = adapter.deliver(notification: Object.new, delivery:, content: { body: "sensitive" }, idempotency_key: "digest")

        assert_equal "failed", result.status
        assert_equal "rejected", result.failure_code
        assert_equal [ { delivery_id: "delivery-2", channel: "email" } ], adapter.calls
        refute adapter.calls.first.key?(:content)
      end
    end
  end
end
