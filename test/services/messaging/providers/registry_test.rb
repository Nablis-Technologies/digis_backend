# frozen_string_literal: true

require "test_helper"

module Messaging
  module Providers
    class RegistryTest < ActiveSupport::TestCase
      class FakeAdapter < Adapter
        def deliver(**)
          DeliveryResult.delivered(provider: "fake")
        end
      end

      test "fetches a registered adapter by channel" do
        registry = Registry.new
        adapter = FakeAdapter.new
        registry.register(channel: "email", adapter:)

        assert_same adapter, registry.fetch(channel: "email")
        assert_nil registry.fetch(channel: "sms")
      end

      test "registration normalizes channel names" do
        registry = Registry.new
        adapter = FakeAdapter.new
        registry.register(channel: " EMAIL ", adapter:)

        assert_same adapter, registry.fetch(channel: "email")
      end

      test "adds defaults without replacing an existing provider registry" do
        registry = Registry.new
        existing = FakeAdapter.new
        registry.register(channel: "email", adapter: existing)

        configured = Registry.configure(registry)

        assert_same registry, configured
        assert_same existing, configured.fetch(channel: "email")
        assert_instance_of InApp, configured.fetch(channel: "in_app")
      end
    end
  end
end
