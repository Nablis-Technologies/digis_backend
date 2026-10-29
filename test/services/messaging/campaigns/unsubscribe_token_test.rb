# frozen_string_literal: true

require "test_helper"

module Messaging
  module Campaigns
    class UnsubscribeTokenTest < ActiveSupport::TestCase
      test "round trips only the suppression identity" do
        token = UnsubscribeToken.issue(
          organization_id: organizations_organizations(:two).id,
          channel: "email",
          channel_address_digest: "a" * 64
        )
        payload = UnsubscribeToken.verify(token)

        assert_equal organizations_organizations(:two).id, payload.fetch("organization_id")
        assert_equal "email", payload.fetch("channel")
        assert_equal "a" * 64, payload.fetch("channel_address_digest")
        assert_equal %w[channel channel_address_digest organization_id], payload.keys.sort
      end

      test "rejects a tampered token" do
        assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
          UnsubscribeToken.verify("tampered")
        end
      end
    end
  end
end
