# frozen_string_literal: true

require "json"
require "test_helper"

module Messaging
  class CampaignsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @organization = organizations_organizations(:two)
      @campaign = Campaign.create!(
        organization: @organization, created_by: core_users(:super_admin),
        name: "API campaign #{SecureRandom.hex(4)}", channel: "email",
        timezone: "Africa/Addis_Ababa", message_body: "Hello"
      )
    end

    test "missing launch key returns bad request" do
      post "/organizations/#{@organization.id}/campaigns/#{@campaign.id}/launch", headers: admin_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", JSON.parse(response.body).fetch("code")
    end

    test "missing estimate key returns bad request" do
      post "/organizations/#{@organization.id}/campaigns/#{@campaign.id}/estimate", headers: admin_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", JSON.parse(response.body).fetch("code")
    end

    test "organizer can attest to an audience before launch" do
      snapshot = CampaignAudienceSnapshot.create!(
        campaign: @campaign, source_spec: { "sources" => [] }, status: "ready", completed_at: Time.current
      )

      post "/organizations/#{@organization.id}/campaigns/#{@campaign.id}/attest",
        params: { confirmation: true, historical_basis: "issued" },
        headers: admin_headers.merge("Idempotency-Key" => "attest-api"), as: :json

      assert_response :success
      assert_equal snapshot.id, CampaignAttestation.find_by!(campaign: @campaign).audience_snapshot_id
    end

    test "organizer can resume a paused campaign" do
      @campaign.update_columns(status: "paused")

      post "/organizations/#{@organization.id}/campaigns/#{@campaign.id}/resume",
        headers: admin_headers.merge("Idempotency-Key" => "resume-api"), as: :json

      assert_response :success
      assert_equal "sending", JSON.parse(response.body).fetch("data").fetch("status")
    end

    test "accepts a nested reason when canceling a campaign" do
      post "/organizations/#{@organization.id}/campaigns/#{@campaign.id}/cancel",
        params: { campaign: { reason: "withdrawn" } },
        headers: admin_headers.merge("Idempotency-Key" => "cancel-nested-reason"), as: :json

      assert_response :success
      assert_equal "canceled", JSON.parse(response.body).dig("data", "status")
    end

    test "a campaign from another organization is not visible" do
      other = organizations_organizations(:one)

      get "/organizations/#{other.id}/campaigns/#{@campaign.id}", headers: admin_headers, as: :json

      assert_response :not_found
    end

    test "show response omits message and provider material" do
      get "/organizations/#{@organization.id}/campaigns/#{@campaign.id}", headers: admin_headers, as: :json

      assert_response :success
      data = JSON.parse(response.body).fetch("data")
      assert_equal @campaign.id, data.fetch("id")
      assert_equal @campaign.launch_version, data.fetch("launch_version")
      refute data.key?("message_body_ciphertext")
      refute data.key?("provider_message_id")
      refute data.key?("credit_ledger_entries")
    end

    test "organizer can create and update safe campaign variables" do
      payload = {
        campaign: {
          name: "Variables API #{SecureRandom.hex(4)}", channel: "email", timezone: "Africa/Addis_Ababa",
          message_body: "Tickets: {{ticket_link}}", variables: { ticket_link: "https://digis.et/tickets" }
        }
      }

      post "/organizations/#{@organization.id}/campaigns", params: payload,
        headers: admin_headers.merge("Idempotency-Key" => "variables-create-api"), as: :json

      assert_response :created
      campaign_id = JSON.parse(response.body).dig("data", "id")
      assert_equal "https://digis.et/tickets", JSON.parse(response.body).dig("data", "variables", "ticket_link")

      patch "/organizations/#{@organization.id}/campaigns/#{campaign_id}",
        params: { campaign: { variables: { ticket_link: "https://digis.et/updated" } } },
        headers: admin_headers.merge("Idempotency-Key" => "variables-update-api"), as: :json

      assert_response :success
      assert_equal "https://digis.et/updated", JSON.parse(response.body).dig("data", "variables", "ticket_link")
    end

    test "analytics returns its aggregate hash directly" do
      get "/organizations/#{@organization.id}/campaigns/#{@campaign.id}/analytics",
        headers: admin_headers, as: :json

      assert_response :success
      assert_equal 0, JSON.parse(response.body).dig("data", "sent")
    end
  end
end
