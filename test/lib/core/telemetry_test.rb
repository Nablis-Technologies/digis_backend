# frozen_string_literal: true

require "test_helper"

class Core::TelemetryTest < ActiveSupport::TestCase
  test "emits only approved operational fields and returns the block value" do
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("digis.orders.place") do |event|
      events << event.payload
    end

    result = Core::Telemetry.instrument(
      "orders.place",
      command_id: "cmd-1",
      organization_id: "org-1",
      outcome: "succeeded",
      email: "secret@example.com"
    ) { :completed }

    assert_equal :completed, result
    assert_equal "cmd-1", events.one? && events.first.fetch(:command_id)
    assert_equal "org-1", events.first.fetch(:organization_id)
    assert_equal "succeeded", events.first.fetch(:outcome)
    refute events.first.key?(:email)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  test "rejects malformed event names" do
    assert_raises(ArgumentError) { Core::Telemetry.instrument("Orders Place") { } }
    assert_raises(ArgumentError) { Core::Telemetry.instrument("orders") { } }
  end

  test "filters sensitive request parameter names" do
    parameters = %w[
      token qr credential lookup_code pnr invitation phone email id_number
      provider_payload webhook_body
    ].index_with { "secret" }
    filtered = ActiveSupport::ParameterFilter.new(
      Rails.application.config.filter_parameters
    ).filter(parameters)

    parameters.each_key do |key|
      refute_equal "secret", filtered.fetch(key)
    end
  end
end
