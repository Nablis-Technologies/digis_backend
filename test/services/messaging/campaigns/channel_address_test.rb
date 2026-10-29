# frozen_string_literal: true

require "test_helper"

module Messaging
  module Campaigns
    class ChannelAddressTest < ActiveSupport::TestCase
      test "normalizes SMS addresses through the canonical Ethiopian identity" do
        assert_equal "251911123456", ChannelAddress.normalize(channel: "sms", value: "0911 123 456")
      end

      test "normalizes email addresses with NFC, trim, and lowercase" do
        assert_equal "user@example.com", ChannelAddress.normalize(channel: "email", value: " User@Example.COM ")
      end

      test "uses channel-specific digest namespaces" do
        assert_equal Core::KeyedDigest.digest(
          namespace: "messaging-campaign-contact-phone", value: "251911123456"
        ), ChannelAddress.digest(channel: "sms", value: "0911123456")
      end
    end
  end
end
