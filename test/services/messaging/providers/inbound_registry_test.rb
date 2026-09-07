# frozen_string_literal: true

require "test_helper"

module Messaging
  module Providers
    class InboundRegistryTest < ActiveSupport::TestCase
      test "registers and resolves inbound adapters by provider" do
        registry = InboundRegistry.configure
        adapter = Class.new(InboundAdapter).new
        registry.register(provider: "fake", adapter:)

        assert_same adapter, registry.fetch(provider: "fake")
      end

      test "rejects adapters that do not implement inbound verification and parsing" do
        registry = InboundRegistry.new

        assert_raises(ArgumentError) do
          registry.register(provider: "invalid", adapter: Object.new)
        end
      end
    end
  end
end
