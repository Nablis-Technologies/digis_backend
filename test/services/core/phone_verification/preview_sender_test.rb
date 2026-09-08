# frozen_string_literal: true

require "test_helper"

module Core
  module PhoneVerification
    class PreviewSenderTest < ActiveSupport::TestCase
      test "fails closed when preview OTP logging is enabled outside Render preview" do
        config = Rails.application.config

        assert_raises RuntimeError do
          with_env("RENDER_PREVIEW" => "false", "DIGIS_PREVIEW_DEBUG_LOGGING" => "true") do
            PreviewSender.configure!(env: ENV, config:)
          end
        end
      end

      test "logs only the challenge and code when explicitly enabled in preview" do
        config = Rails.application.config
        challenge = Struct.new(:id).new("challenge-preview-1")

        Rails.logger.expects(:warn).with { |message|
          message.include?("challenge-preview-1") && message.include?("123456") &&
            !message.include?("+251911234567")
        }
        with_env("RENDER_PREVIEW" => "true", "DIGIS_PREVIEW_DEBUG_LOGGING" => "true") do
          PreviewSender.configure!(env: ENV, config:)
          config.x.phone_verification_sender.call(
            phone: "+251911234567", code: "123456", challenge:
          )
        end
      end

      private

      def with_env(values)
        original = values.to_h { |key, _value| [ key, ENV[key] ] }
        values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        yield
      ensure
        original&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
        Rails.application.config.x.phone_verification_sender = nil
      end
    end
  end
end
