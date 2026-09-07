# frozen_string_literal: true

require "json"
require "test_helper"

module Admin
  module Messaging
    class CampaignsTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers

      setup do
        @organization = organizations_organizations(:two)
        @campaign = ::Messaging::Campaign.create!(
          organization: @organization,
          created_by: core_users(:super_admin),
          name: "Admin campaign #{SecureRandom.hex(4)}",
          channel: "email",
          timezone: "Africa/Addis_Ababa",
          message_body: "Hello"
        )
      end

      test "platform admins can inspect campaigns with safe fields" do
        get "/admin/messaging/campaigns", headers: admin_headers, as: :json

        assert_response :success
        data = JSON.parse(response.body).fetch("data")
        campaign = data.find { |item| item.fetch("id") == @campaign.id }
        assert campaign
        assert_includes campaign.keys, "id"
        assert_includes campaign.keys, "status"
        assert_includes campaign.keys, "timezone"
        refute campaign.key?("message_body_ciphertext")
        refute campaign.key?("provider_message_id")
      end

      test "platform admins can inspect one campaign" do
        get "/admin/messaging/campaigns/#{@campaign.id}", headers: admin_headers, as: :json

        assert_response :success
        assert_equal @campaign.id, JSON.parse(response.body).dig("data", "id")
      end

      test "non-platform admins cannot inspect campaigns" do
        get "/admin/messaging/campaigns", headers: owner_headers, as: :json

        assert_response :forbidden
      end

      test "platform admins can create and replay a baseline template" do
        payload = { campaign_template: { name: "Admin baseline #{SecureRandom.hex(4)}", channel: "email" } }
        headers = admin_headers.merge("Idempotency-Key" => "admin-template-create-1")

        assert_difference -> { ::Messaging::CampaignTemplate.count }, 1 do
          post "/admin/messaging/campaign_templates", params: payload, headers:, as: :json
          assert_response :created

          post "/admin/messaging/campaign_templates", params: payload, headers:, as: :json
          assert_response :created
        end

        data = JSON.parse(response.body).fetch("data")
        assert_nil data.fetch("organization_id")
      end

      test "a baseline template replay with different content is rejected" do
        key = "admin-template-conflict-1"
        post "/admin/messaging/campaign_templates",
          params: { campaign_template: { name: "Baseline A", channel: "email" } },
          headers: admin_headers.merge("Idempotency-Key" => key), as: :json
        assert_response :created

        post "/admin/messaging/campaign_templates",
          params: { campaign_template: { name: "Baseline B", channel: "email" } },
          headers: admin_headers.merge("Idempotency-Key" => key), as: :json

        assert_response :conflict
        assert_equal "idempotency_conflict", JSON.parse(response.body).fetch("code")
      end

      test "baseline template mutations require an idempotency key" do
        post "/admin/messaging/campaign_templates",
          params: { campaign_template: { name: "Missing key", channel: "sms" } },
          headers: admin_headers, as: :json

        assert_response :bad_request
        assert_equal "missing_idempotency_key", JSON.parse(response.body).fetch("code")
      end

      test "platform admins can update a volume policy and replay it" do
        policy = ::Messaging::CampaignVolumePolicy.create!(
          organization: @organization, channel: "email", timezone: "Africa/Addis_Ababa",
          daily_limit: 100, monthly_limit: 2_000, updated_by: core_users(:super_admin),
          idempotency_key_digest: "a" * 64, request_digest: "b" * 64
        )
        payload = { campaign_volume_policy: { daily_limit: 200, monthly_limit: 4_000 } }
        headers = admin_headers.merge("Idempotency-Key" => "admin-volume-policy-update-1")

        patch "/admin/messaging/campaign_volume_policies/#{policy.id}",
          params: payload, headers:, as: :json
        assert_response :success
        assert_equal 200, JSON.parse(response.body).dig("data", "daily_limit")

        patch "/admin/messaging/campaign_volume_policies/#{policy.id}",
          params: payload, headers:, as: :json
        assert_response :success
        assert_equal 200, policy.reload.daily_limit
      end

      test "a volume policy replay with different content is rejected" do
        policy = ::Messaging::CampaignVolumePolicy.create!(
          organization: @organization, channel: "email", timezone: "Africa/Addis_Ababa",
          daily_limit: 100, monthly_limit: 2_000, updated_by: core_users(:super_admin),
          idempotency_key_digest: "e" * 64, request_digest: "f" * 64
        )
        headers = admin_headers.merge("Idempotency-Key" => "admin-volume-policy-conflict-1")

        patch "/admin/messaging/campaign_volume_policies/#{policy.id}",
          params: { campaign_volume_policy: { daily_limit: 200, monthly_limit: 4_000 } },
          headers:, as: :json
        assert_response :success

        patch "/admin/messaging/campaign_volume_policies/#{policy.id}",
          params: { campaign_volume_policy: { daily_limit: 300, monthly_limit: 4_000 } },
          headers:, as: :json

        assert_response :conflict
        assert_equal "idempotency_conflict", JSON.parse(response.body).fetch("code")
      end

      test "volume policy mutations require an idempotency key" do
        policy = ::Messaging::CampaignVolumePolicy.create!(
          organization: @organization, channel: "sms", timezone: "Africa/Addis_Ababa",
          daily_limit: 100, monthly_limit: 2_000, updated_by: core_users(:super_admin),
          idempotency_key_digest: "c" * 64, request_digest: "d" * 64
        )

        patch "/admin/messaging/campaign_volume_policies/#{policy.id}",
          params: { campaign_volume_policy: { daily_limit: 200 } },
          headers: admin_headers, as: :json

        assert_response :bad_request
        assert_equal "missing_idempotency_key", JSON.parse(response.body).fetch("code")
      end
    end
  end
end
