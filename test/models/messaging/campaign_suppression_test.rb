# frozen_string_literal: true

require "test_helper"

module Messaging
  class CampaignSuppressionTest < ActiveSupport::TestCase
    test "normalizes scoped suppression fields" do
      suppression = CampaignSuppression.new(
        channel: " SMS ",
        channel_address_digest: "A" * 64,
        source: " provider ",
        reason: " STOP ",
        suppressed_at: Time.current,
        idempotency_key_digest: "B" * 64
      )

      assert suppression.valid?
      assert_equal "sms", suppression.channel
      assert_equal "a" * 64, suppression.channel_address_digest
      assert_equal "provider", suppression.source
      assert_equal "STOP", suppression.reason
      assert_equal "b" * 64, suppression.idempotency_key_digest
    end

    test "rejects an invalid channel digest" do
      suppression = CampaignSuppression.new(
        channel: "sms", channel_address_digest: "not-a-digest",
        source: "provider", reason: "stop", suppressed_at: Time.current,
        idempotency_key_digest: "c" * 64
      )

      refute suppression.valid?
      assert suppression.errors[:channel_address_digest].any?
    end
  end
end
