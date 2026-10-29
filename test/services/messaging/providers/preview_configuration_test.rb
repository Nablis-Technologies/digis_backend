# frozen_string_literal: true

require "test_helper"

module Messaging
  module Providers
    class PreviewConfigurationTest < ActiveSupport::TestCase
      test "registers SMS and email only when preview mode is explicitly enabled" do
        registry = Registry.new

        with_env("RENDER_PREVIEW" => "true", "DIGIS_MESSAGING_PREVIEW_PROVIDER" => "true") do
          PreviewConfiguration.call(env: ENV, registry:)
        end

        assert_instance_of PreviewAdapter, registry.fetch(channel: "sms")
        assert_instance_of PreviewAdapter, registry.fetch(channel: "email")
      end

      test "leaves the registry unchanged when the preview provider is disabled" do
        registry = Registry.new

        with_env("RENDER_PREVIEW" => "true", "DIGIS_MESSAGING_PREVIEW_PROVIDER" => "false") do
          PreviewConfiguration.call(env: ENV, registry:)
        end

        assert_nil registry.fetch(channel: "sms")
        assert_nil registry.fetch(channel: "email")
      end

      test "fails closed when the preview provider is enabled outside Render preview" do
        registry = Registry.new

        assert_raises RuntimeError do
          with_env("RENDER_PREVIEW" => "false", "DIGIS_MESSAGING_PREVIEW_PROVIDER" => "true") do
            PreviewConfiguration.call(env: ENV, registry:)
          end
        end
      end

      test "rejects an invalid configured outcome before registration" do
        registry = Registry.new

        assert_raises ArgumentError do
          with_env(
            "RENDER_PREVIEW" => "true", "DIGIS_MESSAGING_PREVIEW_PROVIDER" => "true",
            "DIGIS_MESSAGING_PREVIEW_OUTCOME" => "provider_magic"
          ) { PreviewConfiguration.call(env: ENV, registry:) }
        end

        assert_nil registry.fetch(channel: "sms")
      end

      private

      def with_env(values)
        original = values.to_h { |key, _value| [ key, ENV[key] ] }
        values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        yield
      ensure
        original&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
      end
    end
  end
end
