# frozen_string_literal: true

require "test_helper"

class FinancePayoutProvidersConfigurationTest < ActiveSupport::TestCase
  setup do
    Finance::PayoutProviders::Registry.instance_variable_set(:@adapters, {})
  end

  teardown do
    Finance::PayoutProviders::Registry.instance_variable_set(:@adapters, {})
  end

  test "registers Chapa V2 payouts only when payment and payout integration are enabled" do
    with_env(
      "CHAPA_ENABLED" => "true",
      "CHAPA_PAYOUT_ENABLED" => "true",
      "CHAPA_MODE" => "test",
      "CHAPA_SECRET_KEY" => "CHAPA_TEST_payout-config-test",
      "RENDER_PREVIEW" => "true"
    ) do
      Finance::PayoutProviders::Registration.call(env: ENV)
    end

    adapter = Finance::PayoutProviders::Registry.fetch("chapa")
    assert_equal %w[ETB USD], adapter.capabilities.fetch(:currencies)
    assert_equal({ supported: true }, adapter.capabilities.fetch(:payouts))
    assert_equal({ supported: false }, adapter.capabilities.fetch(:balance_api))
  end

  test "does not register Chapa payouts when payout integration is disabled" do
    with_env(
      "CHAPA_ENABLED" => "true",
      "CHAPA_PAYOUT_ENABLED" => "false",
      "CHAPA_MODE" => "test",
      "CHAPA_SECRET_KEY" => "CHAPA_TEST_payout-config-test",
      "RENDER_PREVIEW" => "true"
    ) do
      Finance::PayoutProviders::Registration.call(env: ENV)
    end

    assert_empty Finance::PayoutProviders::Registry.available
  end

  test "fails closed when the Chapa secret is missing" do
    with_env(
      "CHAPA_ENABLED" => "true",
      "CHAPA_PAYOUT_ENABLED" => "true",
      "CHAPA_MODE" => "test",
      "CHAPA_SECRET_KEY" => nil,
      "RENDER_PREVIEW" => "true"
    ) do
      Finance::PayoutProviders::Registration.call(env: ENV)
    end

    assert_empty Finance::PayoutProviders::Registry.available
  end

  test "rejects live Chapa payout mode in the Render preview" do
    assert_raises(RuntimeError) do
      with_env(
        "CHAPA_ENABLED" => "true",
        "CHAPA_PAYOUT_ENABLED" => "true",
        "CHAPA_MODE" => "live",
        "CHAPA_SECRET_KEY" => "CHAPA_LIVE_payout-config-test",
        "RENDER_PREVIEW" => "true"
      ) do
        Finance::PayoutProviders::Registration.call(env: ENV)
      end
    end
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
