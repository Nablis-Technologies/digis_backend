# frozen_string_literal: true

require "test_helper"

module Messaging
  class ResolveCreditRateTest < ActiveSupport::TestCase
    setup do
      @organization = organizations_organizations(:one)
      @other_organization = organizations_organizations(:two)
      @now = Time.utc(2026, 9, 4, 12)
    end

    test "uses organization country rate before global and default rates" do
      create_rate(unit_price_minor: 70)
      create_rate(organization: @organization, unit_price_minor: 60)
      create_rate(country_code: "ET", unit_price_minor: 50)
      organization_country = create_rate(
        organization: @organization, country_code: "ET", unit_price_minor: 40
      )

      result = ResolveCreditRate.call(
        organization: @organization, channel: "sms", country_code: "ET",
        quantity: 10, currency: "ETB", at: @now
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal organization_country, result.value.fetch(:rate_version)
      assert_equal 40, result.value.fetch(:unit_price_minor)
    end

    test "falls back from organization country to global country and default scopes" do
      global_country = create_rate(country_code: "ET", unit_price_minor: 50)

      result = ResolveCreditRate.call(
        organization: @other_organization, channel: "sms", country_code: "ET",
        quantity: 1, currency: "ETB", at: @now
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal global_country, result.value.fetch(:rate_version)
    end

    test "selects the volume tier containing the requested quantity" do
      rate = create_rate(
        channel: "email", unit_price_minor: 100,
        volume_tiers: [
          { "from" => 1, "to" => 99, "unit_price_minor" => 100 },
          { "from" => 100, "to" => nil, "unit_price_minor" => 70 }
        ]
      )

      result = ResolveCreditRate.call(
        organization: @organization, channel: "email", quantity: 100,
        currency: "ETB", at: @now
      )

      assert_predicate result, :success?, result.error&.message
    assert_equal rate, result.value.fetch(:rate_version)
    assert_equal 70, result.value.fetch(:unit_price_minor)
  end

    test "rejects multiple active versions instead of choosing arbitrarily" do
      create_rate(version: 1, unit_price_minor: 10)
      create_rate(version: 2, unit_price_minor: 7)

      result = ResolveCreditRate.call(
        organization: @organization, channel: "sms", quantity: 75,
        currency: "ETB", at: @now
      )

      assert_predicate result, :failure?
      assert_equal "rate_unavailable", result.error.code
    end

    test "rejects a missing or currency-mismatched rate" do
      missing = ResolveCreditRate.call(
        organization: @organization, channel: "sms", quantity: 1,
        currency: "ETB", at: @now
      )
      assert_predicate missing, :failure?
      assert_equal "rate_unavailable", missing.error.code

      create_rate(currency: "USD")
      mismatched = ResolveCreditRate.call(
        organization: @organization, channel: "sms", quantity: 1,
        currency: "ETB", at: @now
      )
      assert_predicate mismatched, :failure?
      assert_equal "rate_unavailable", mismatched.error.code
    end

    test "labels an organization default rate correctly when country is omitted" do
      default_rate = create_rate(organization: @organization, unit_price_minor: 33)

      result = ResolveCreditRate.call(
        organization: @organization, channel: "sms", quantity: 1,
        currency: "ETB", at: @now
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal default_rate, result.value.fetch(:rate_version)
      assert_equal "organization_default", result.value.fetch(:scope)
    end

    test "resolves a global default rate without an organization" do
      global_rate = create_rate(organization: nil, unit_price_minor: 44)

      result = ResolveCreditRate.call(
        organization: nil, channel: "sms", quantity: 1,
        currency: "ETB", at: @now
      )

      assert_predicate result, :success?, result.error&.message
      assert_equal global_rate, result.value.fetch(:rate_version)
      assert_equal "global_default", result.value.fetch(:scope)
    end

    test "ignores rates outside their effective window" do
      create_rate(effective_from: @now + 1.hour)
      create_rate(effective_from: @now - 2.days, effective_until: @now - 1.hour)

      result = ResolveCreditRate.call(
        organization: @organization, channel: "sms", quantity: 1,
        currency: "ETB", at: @now
      )

      assert_predicate result, :failure?
      assert_equal "rate_unavailable", result.error.code
    end

    private

    def create_rate(
      organization: nil, channel: "sms", country_code: nil, currency: "ETB",
      unit_price_minor: 50, volume_tiers: [], effective_from: @now - 1.day,
      effective_until: nil, version: nil
    )
      version ||= Messaging::CreditRateVersion.where(
        organization:, channel:, country_code:
      ).maximum(:version).to_i + 1
      Messaging::CreditRateVersion.create!(
        organization:, channel:, country_code:, currency:, version:,
        unit_price_minor:, volume_tiers:, effective_from:, effective_until:,
        status: "active",
        idempotency_key_digest: Digest::SHA256.hexdigest("#{channel}-#{country_code}-#{version}"),
        request_digest: Digest::SHA256.hexdigest("request-#{channel}-#{country_code}-#{version}"),
        activated_at: @now - 1.hour
      )
    end
  end
end
