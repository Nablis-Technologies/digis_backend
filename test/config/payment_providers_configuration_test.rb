# frozen_string_literal: true

require "test_helper"

class PaymentProvidersConfigurationTest < ActiveSupport::TestCase
  setup do
    Payments::Providers::Registry.instance_variable_set(:@adapters, {})
  end

  teardown do
    Payments::Providers::Registry.instance_variable_set(:@adapters, {})
  end

  test "registers Chapa only when explicitly enabled with test credentials" do
    with_env(
      "CHAPA_ENABLED" => "true",
      "CHAPA_MODE" => "test",
      "CHAPA_SECRET_KEY" => "CHAPA_TEST_config-test",
      "CHAPA_WEBHOOK_SECRET" => "webhook-secret",
      "RENDER_PREVIEW" => "true"
    ) do
      Payments::Providers::Registration.call(env: ENV)
    end

    adapter = Payments::Providers::Registry.fetch("chapa")
    assert_equal %w[ETB USD], adapter.capabilities.fetch(:currencies)
    assert_equal %w[telebirr cbebirr mpesa awashbirr ebirr enat_bank card bank],
      adapter.capabilities.fetch(:payment_methods)
  end

  test "rejects live Chapa mode in the Render preview" do
    assert_raises(RuntimeError) do
      with_env(
        "CHAPA_ENABLED" => "true",
        "CHAPA_MODE" => "live",
        "CHAPA_SECRET_KEY" => "CHAPA_LIVE_config-test",
        "CHAPA_WEBHOOK_SECRET" => "webhook-secret",
        "RENDER_PREVIEW" => "true"
      ) do
        Payments::Providers::Registration.call(env: ENV)
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
