# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class CreditRateVersionTest < ActiveSupport::TestCase
    setup do
      @rate = CreditRateVersion.new(
        channel: "sms", version: 1, currency: "ETB", unit_price_minor: 10,
        effective_from: Time.current, status: "active", activated_at: Time.current,
        idempotency_key_digest: Digest::SHA256.hexdigest("rate-model"),
        request_digest: Digest::SHA256.hexdigest("rate-model-request")
      )
    end

    test "rejects malformed and overlapping volume tiers" do
      @rate.volume_tiers = [
        { "from" => 1, "to" => 100, "unit_price_minor" => 10 },
        { "from" => 50, "to" => 150, "unit_price_minor" => 8 }
      ]

      assert_not @rate.valid?
      assert_includes @rate.errors.attribute_names, :volume_tiers
    end

    test "keeps pricing snapshots immutable after persistence" do
      @rate.save!
      @rate.unit_price_minor = 12

      assert_not @rate.valid?
      assert_includes @rate.errors.attribute_names, :unit_price_minor
    end
  end
end
