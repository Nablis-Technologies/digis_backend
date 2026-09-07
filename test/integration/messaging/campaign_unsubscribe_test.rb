# frozen_string_literal: true

require "json"
require "test_helper"

module Messaging
  class CampaignUnsubscribeTest < ActionDispatch::IntegrationTest
    setup do
      @organization = organizations_organizations(:two)
      @digest = Core::KeyedDigest.digest(
        namespace: "messaging-campaign-contact-email", value: "unsubscribe@example.com"
      )
      @token = Campaigns::UnsubscribeToken.issue(
        organization_id: @organization.id, channel: "email", channel_address_digest: @digest
      )
    end

    test "previews a tokenized unsubscribe without mutating suppression state" do
      get "/messaging/unsubscribe/#{@token}"

      assert_response :success
      assert_equal true, JSON.parse(response.body).fetch("data").fetch("valid")
      assert_equal "email", JSON.parse(response.body).fetch("data").fetch("channel")
      assert_not CampaignSuppression.exists?(organization: @organization, channel: "email",
        channel_address_digest: @digest)
    end

    test "records a tokenized unsubscribe through POST without authentication" do
      post "/messaging/unsubscribe/#{@token}"

      assert_response :success
      assert_equal "email", JSON.parse(response.body).fetch("data").fetch("channel")
      assert CampaignSuppression.exists?(organization: @organization, channel: "email",
        channel_address_digest: @digest)
    end

    test "rejects a tampered unsubscribe token" do
      get "/messaging/unsubscribe/tampered"

      assert_response :bad_request
      assert_equal "invalid_unsubscribe_token", JSON.parse(response.body).fetch("code")
    end

    test "rejects an unsubscribe token whose organization no longer exists" do
      token = Campaigns::UnsubscribeToken.issue(
        organization_id: "00000000-0000-0000-0000-000000000000", channel: "email",
        channel_address_digest: @digest
      )

      post "/messaging/unsubscribe/#{token}"

      assert_response :bad_request
      assert_equal "invalid_unsubscribe_token", JSON.parse(response.body).fetch("code")
      assert_not CampaignSuppression.exists?(organization_id: nil, channel: "email",
        channel_address_digest: @digest)
    end
  end
end
