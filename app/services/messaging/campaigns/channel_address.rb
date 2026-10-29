# frozen_string_literal: true

module Messaging
  module Campaigns
    # Normalizes and digests one campaign channel address consistently.
    class ChannelAddress
      def self.normalize(channel:, value:)
        new(channel:, value:).normalize
      end

      def self.digest(channel:, value:)
        address = normalize(channel:, value:)
        return if address.blank?

        namespace = channel.to_s.strip.downcase == "sms" ? "messaging-campaign-contact-phone" : "messaging-campaign-contact-email"
        Core::KeyedDigest.digest(namespace:, value: address)
      end

      def initialize(channel:, value:)
        @channel = channel.to_s.strip.downcase
        @value = value
      end

      def normalize
        case @channel
        when "sms"
          Core::PhoneIdentity::ResolveOrCreate.normalize(@value)
        when "email"
          @value.to_s.unicode_normalize(:nfc).strip.downcase.presence
        end
      end
    end
  end
end
