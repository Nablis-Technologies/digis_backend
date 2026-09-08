# frozen_string_literal: true

require "test_helper"

class MarketplacePayoutProvidersConfigurationTest < ActiveSupport::TestCase
  setup do
    Marketplace::PayoutProviders::Registry.instance_variable_set(:@adapters, {})
  end

  teardown do
    Marketplace::PayoutProviders::Registry.instance_variable_set(:@adapters, {})
  end

  test "registers the shared Chapa transfer adapter when payouts are enabled" do
    with_env(
      "CHAPA_ENABLED" => "true",
      "CHAPA_PAYOUT_ENABLED" => "true",
      "CHAPA_MODE" => "test",
      "CHAPA_SECRET_KEY" => "CHASECK_TEST-marketplace-config-test",
      "RENDER_PREVIEW" => "true"
    ) { Marketplace::PayoutProviders::Registration.call(env: ENV) }

    adapter = Marketplace::PayoutProviders::Registry.fetch("chapa")
    assert_equal true, adapter.capabilities.dig(:payouts, :supported)
    assert_equal false, adapter.capabilities.dig(:destination_registration, :supported)
  end

  test "does not register Chapa when marketplace payout prerequisites are absent" do
    with_env(
      "CHAPA_ENABLED" => "true",
      "CHAPA_PAYOUT_ENABLED" => "false",
      "CHAPA_MODE" => "test",
      "CHAPA_SECRET_KEY" => "CHASECK_TEST-marketplace-config-test",
      "RENDER_PREVIEW" => "true"
    ) { Marketplace::PayoutProviders::Registration.call(env: ENV) }

    assert_empty Marketplace::PayoutProviders::Registry.available
  end

  test "fails closed when the marketplace Chapa secret is missing" do
    with_env(
      "CHAPA_ENABLED" => "true",
      "CHAPA_PAYOUT_ENABLED" => "true",
      "CHAPA_MODE" => "test",
      "CHAPA_SECRET_KEY" => nil,
      "RENDER_PREVIEW" => "true"
    ) do
      Marketplace::PayoutProviders::Registration.call(env: ENV)
    end

    assert_empty Marketplace::PayoutProviders::Registry.available
  end

  private

  def with_env(values)
    original = values.to_h { |key, _value| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
