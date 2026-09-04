# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class EstimateCreditTopUpTest < ActiveSupport::TestCase
    setup do
      @organization = organizations_organizations(:one)
      @now = Time.utc(2026, 9, 4, 12)
      @rate = Messaging::CreditRateVersion.create!(
        channel: "sms", version: 1, currency: "ETB", unit_price_minor: 50,
        volume_tiers: [], effective_from: @now - 1.hour, status: "active",
        idempotency_key_digest: Digest::SHA256.hexdigest("rate"),
        request_digest: Digest::SHA256.hexdigest("rate-request"),
        activated_at: @now - 1.hour
      )
    end

    test "returns an immutable rate and integer total without writing credits" do
      before = Messaging::CreditTopUp.count

      result = EstimateCreditTopUp.call(
        organization: @organization, channel: "sms", quantity: 10,
        currency: "ETB", country_code: "ET", at: @now
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal @rate, result.value.fetch(:rate_version)
      assert_equal 50, result.value.fetch(:unit_price_minor)
      assert_equal 500, result.value.fetch(:amount_minor)
      assert_equal before, Messaging::CreditTopUp.count
    end

    test "rejects non-positive quantities and unavailable rates" do
      invalid = EstimateCreditTopUp.call(
        organization: @organization, channel: "sms", quantity: 0,
        currency: "ETB", at: @now
      )
      assert_predicate invalid, :failure?
      assert_equal "invalid_credit_quantity", invalid.error.code

      unavailable = EstimateCreditTopUp.call(
        organization: @organization, channel: "push", quantity: 1,
        currency: "ETB", at: @now
      )
      assert_predicate unavailable, :failure?
      assert_equal "rate_unavailable", unavailable.error.code
    end
  end
end
