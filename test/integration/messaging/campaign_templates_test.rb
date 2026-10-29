# frozen_string_literal: true

require "json"
require "test_helper"

module Messaging
  class CampaignTemplatesTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    test "creates a safe organizer template projection" do
      organization = organizations_organizations(:two)
      post "/organizations/#{organization.id}/campaign_templates",
        params: { campaign_template: { name: "Welcome", channel: "email", status: "draft" } },
        headers: admin_headers.merge("Idempotency-Key" => "template-1"), as: :json

      assert_response :created
      data = JSON.parse(response.body).fetch("data")
      assert_equal "email", data.fetch("channel")
      refute data.key?("metadata")
    end

    test "replays an organizer template create without a second row" do
      organization = organizations_organizations(:two)
      payload = { campaign_template: { name: "Replay #{SecureRandom.hex(4)}", channel: "email", status: "draft" } }
      headers = admin_headers.merge("Idempotency-Key" => "organizer-template-replay")

      assert_difference -> { CampaignTemplate.count }, 1 do
        post "/organizations/#{organization.id}/campaign_templates", params: payload, headers:, as: :json
        assert_response :created

        post "/organizations/#{organization.id}/campaign_templates", params: payload, headers:, as: :json
        assert_response :created
      end
    end

    test "rejects an organizer template replay with different content" do
      organization = organizations_organizations(:two)
      key = "organizer-template-conflict"
      post "/organizations/#{organization.id}/campaign_templates",
        params: { campaign_template: { name: "Template A", channel: "email", status: "draft" } },
        headers: admin_headers.merge("Idempotency-Key" => key), as: :json
      assert_response :created

      post "/organizations/#{organization.id}/campaign_templates",
        params: { campaign_template: { name: "Template B", channel: "email", status: "draft" } },
        headers: admin_headers.merge("Idempotency-Key" => key), as: :json

      assert_response :conflict
      assert_equal "idempotency_conflict", JSON.parse(response.body).fetch("code")
    end

    test "returns a typed conflict for a duplicate organizer template name" do
      organization = organizations_organizations(:two)
      name = "Duplicate #{SecureRandom.hex(4)}"
      payload = { campaign_template: { name:, channel: "email", status: "draft" } }
      post "/organizations/#{organization.id}/campaign_templates",
        params: payload, headers: admin_headers.merge("Idempotency-Key" => "organizer-template-name-1"), as: :json
      assert_response :created

      post "/organizations/#{organization.id}/campaign_templates",
        params: payload, headers: admin_headers.merge("Idempotency-Key" => "organizer-template-name-2"), as: :json

      assert_response :conflict
      assert_equal "campaign_template_name_taken", JSON.parse(response.body).fetch("code")
    end
  end
end
