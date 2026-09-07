# frozen_string_literal: true

require "test_helper"

module Messaging
  module Providers
    class PreviewAdapterTest < ActiveSupport::TestCase
      test "returns the configured result for campaign and notification delivery" do
        adapter = PreviewAdapter.new(outcome: "delivered")
        delivery = Struct.new(:id, :channel).new("delivery-1", "sms")

        campaign_result = adapter.deliver_campaign(
          campaign: Object.new, delivery:, content: {}, idempotency_key: "digest"
        )
        notification_result = adapter.deliver(
          notification: Object.new, delivery:, content: {}, idempotency_key: "digest"
        )

        assert_predicate campaign_result, :success?
        assert_equal "delivered", campaign_result.status
        assert_equal "delivered", notification_result.status
        assert_equal "preview", campaign_result.provider
      end

      test "supports every configured provider outcome" do
        delivery = Struct.new(:id, :channel).new("delivery-2", "email")

        {
          "delivered" => [ "delivered", true ],
          "sent" => [ "sent", true ],
          "failed" => [ "failed", false ],
          "retryable" => [ "failed", false ]
        }.each do |outcome, (status, successful)|
          result = PreviewAdapter.new(outcome:).deliver_campaign(
            campaign: Object.new, delivery:, content: {}, idempotency_key: "digest"
          )

          assert_equal status, result.status
          assert_equal successful, result.success?
        end
      end

      test "rejects an unknown outcome" do
        assert_raises ArgumentError do
          PreviewAdapter.new(outcome: "provider_magic")
        end
      end
    end
  end
end
