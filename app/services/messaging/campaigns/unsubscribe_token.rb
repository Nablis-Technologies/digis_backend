# frozen_string_literal: true

module Messaging
  module Campaigns
    # Signs only the channel/scope identity used by public unsubscribe links.
    class UnsubscribeToken
      PURPOSE = "campaign_unsubscribe"
      VERIFIER_NAME = "messaging-campaign-unsubscribe-v1"
      TTL = 30.days
      FIELDS = %w[organization_id channel channel_address_digest].freeze

      def self.issue(organization_id:, channel:, channel_address_digest:)
        payload = {
          "organization_id" => organization_id,
          "channel" => channel.to_s.strip.downcase,
          "channel_address_digest" => channel_address_digest.to_s.strip.downcase
        }
        verifier.generate(payload, purpose: PURPOSE, expires_in: TTL)
      end

      def self.verify(token)
        payload = verifier.verify(token, purpose: PURPOSE).stringify_keys
        return payload if payload.keys.sort == FIELDS.sort

        raise ActiveSupport::MessageVerifier::InvalidSignature
      end

      def self.verifier
        Rails.application.message_verifier(VERIFIER_NAME)
      end
      private_class_method :verifier
    end
  end
end
