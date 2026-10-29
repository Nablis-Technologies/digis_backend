# frozen_string_literal: true

require "test_helper"

module Messaging
  module Providers
    class PreviewAdapterTest < ActiveSupport::TestCase
      test "returns the configured result for campaign and notification delivery" do
        adapter = PreviewAdapter.new(outcome: "delivered")
        delivery = Struct.new(:id, :channel).new("delivery-1", "sms")

        campaign_result = adapter.deliver_campaign(
          campaign: Object.new, delivery:, content: {}, idempotency_key: "digest"
        )
        notification_result = adapter.deliver(
          notification: Object.new, delivery:, content: {}, idempotency_key: "digest"
        )

        assert_predicate campaign_result, :success?
        assert_equal "delivered", campaign_result.status
        assert_equal "delivered", notification_result.status
        assert_equal "preview", campaign_result.provider
      end

      test "supports every configured provider outcome" do
        delivery = Struct.new(:id, :channel).new("delivery-2", "email")

        {
          "delivered" => [ "delivered", true ],
          "sent" => [ "sent", true ],
          "failed" => [ "failed", false ],
          "retryable" => [ "failed", false ]
        }.each do |outcome, (status, successful)|
          result = PreviewAdapter.new(outcome:).deliver_campaign(
            campaign: Object.new, delivery:, content: {}, idempotency_key: "digest"
          )

          assert_equal status, result.status
          assert_equal successful, result.success?
        end
      end

      test "rejects an unknown outcome" do
        assert_raises ArgumentError do
          PreviewAdapter.new(outcome: "provider_magic")
        end
      end

      test "logs an SMS body only for an explicitly enabled Render preview" do
        Rails.logger.expects(:warn).with { |message|
          message.include?("Your ticket is ready") && !message.include?("+251911234567")
        }
        with_env("RENDER_PREVIEW" => "true", "DIGIS_PREVIEW_DEBUG_LOGGING" => "true") do
          result = PreviewAdapter.new.deliver_sms(
            phone: "+251911234567",
            body: "Your ticket is ready: http://preview.test/t-abc123",
            idempotency_key: "digest"
          )

          assert_predicate result, :success?
        end
      end

      test "does not log an SMS body when preview debug logging is disabled" do
        Rails.logger.expects(:warn).never
        with_env("RENDER_PREVIEW" => "true", "DIGIS_PREVIEW_DEBUG_LOGGING" => "false") do
          result = PreviewAdapter.new.deliver_sms(
            phone: "+251911234567",
            body: "Your ticket is ready: http://preview.test/t-abc123",
            idempotency_key: "digest"
          )

          assert_predicate result, :success?
        end
      end

      test "logs an email body only for an explicitly enabled Render preview" do
        Rails.logger.expects(:warn).with { |message|
          message.include?("Ticket transfer") && message.include?("http://preview.test/x-abc123") &&
            !message.include?("recipient@example.com")
        }
        with_env("RENDER_PREVIEW" => "true", "DIGIS_PREVIEW_DEBUG_LOGGING" => "true") do
          result = PreviewAdapter.new.deliver_email(
            to: "recipient@example.com",
            subject: "Ticket transfer",
            body: "Ticket transfer: http://preview.test/x-abc123",
            idempotency_key: "digest"
          )

          assert_predicate result, :success?
        end
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
