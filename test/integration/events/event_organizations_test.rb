# frozen_string_literal: true

require "test_helper"

module Events
  class EventOrganizationsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    def setup
      @event = events_events(:ready_listing)
      @org_three = organizations_organizations(:three)
    end

    test "owner can add a collaborator organization without sending status" do
      assert_difference -> { Events::EventOrganization.count }, 1 do
        post "/events/#{@event.id}/event_organizations",
             params: { event_organization: { organization_id: @org_three.id, type: "co_organizer", role: "collaborator" } },
             headers: owner_headers, as: :json
      end
      assert_response :created
      org = Events::EventOrganization.find_by(event: @event, organization: @org_three)
      assert org
      assert_equal "active", org.status
      assert_equal I18n.t("event_organization.success.create"), JSON.parse(response.body)["message"]
    end

    test "server forces status to active even if client tries to set it" do
      post "/events/#{@event.id}/event_organizations",
           params: { event_organization: { organization_id: @org_three.id, type: "co_organizer", role: "collaborator", status: "revoked" } },
           headers: owner_headers, as: :json
      assert_response :created
      org = Events::EventOrganization.find_by(event: @event, organization: @org_three)
      assert_equal "active", org.status
    end

    test "owner cannot add a collaborator with primary_owner role" do
      post "/events/#{@event.id}/event_organizations",
           params: { event_organization: { organization_id: @org_three.id, type: "co_organizer", role: "primary_owner" } },
           headers: owner_headers, as: :json
      assert_response :unprocessable_entity
    end

    test "outsider cannot add a collaborator organization" do
      post "/events/#{@event.id}/event_organizations",
           params: { event_organization: { organization_id: @org_three.id, type: "co_organizer", role: "collaborator" } },
           headers: user_headers, as: :json
      assert_response :forbidden
    end

    test "owner can revoke a collaborator organization" do
      org = Events::EventOrganization.create!(event: @event, organization: @org_three, type: "co_organizer", role: "collaborator", status: "active")
      post "/events/#{@event.id}/event_organizations/#{org.id}/revoke", headers: owner_headers, as: :json
      assert_response :ok
      assert_equal I18n.t("event_organization.success.revoke"), JSON.parse(response.body)["message"]
      assert_equal "revoked", org.reload.status
    end

    test "owner can activate a revoked collaborator organization" do
      org = Events::EventOrganization.create!(event: @event, organization: @org_three, type: "co_organizer", role: "collaborator", status: "revoked")
      post "/events/#{@event.id}/event_organizations/#{org.id}/activate", headers: owner_headers, as: :json
      assert_response :ok
      assert_equal I18n.t("event_organization.success.activate"), JSON.parse(response.body)["message"]
      assert_equal "active", org.reload.status
    end

    test "update cannot change status through the request body" do
      org = Events::EventOrganization.create!(event: @event, organization: @org_three, type: "co_organizer", role: "collaborator", status: "active")
      patch "/events/#{@event.id}/event_organizations/#{org.id}",
            params: { event_organization: { role: "sponsor", status: "revoked" } },
            headers: owner_headers, as: :json
      assert_response :ok
      org.reload
      assert_equal "sponsor", org.role
      assert_equal "active", org.status
      assert_equal I18n.t("event_organization.success.update"), JSON.parse(response.body)["message"]
    end

    test "outsider cannot revoke a collaborator organization" do
      org = Events::EventOrganization.create!(event: @event, organization: @org_three, type: "co_organizer", role: "collaborator", status: "active")
      post "/events/#{@event.id}/event_organizations/#{org.id}/revoke", headers: user_headers, as: :json
      assert_response :forbidden
      assert_equal "active", org.reload.status
    end

    test "index returns a stable primary organization and collaborator summaries" do
      collaborator = Events::EventOrganization.create!(
        event: @event,
        organization: @org_three,
        type: "co_organizer",
        role: "collaborator",
        status: "active"
      )

      get "/events/#{@event.id}/event_organizations", headers: owner_headers, as: :json
      assert_response :ok

      data = JSON.parse(response.body).fetch("data")
      assert_equal @event.organization_id, data.dig("primary_organization", "id")
      assert_equal @event.organization.name, data.dig("primary_organization", "name")
      collaborator_data = data.fetch("collaborators").find { |entry| entry.fetch("id") == collaborator.id }
      assert_equal @org_three.name, collaborator_data.dig("organization", "name")
      assert_equal "active", collaborator_data.fetch("status")
    end

    test "index bounds and paginates persisted collaborators" do
      Events::EventOrganization.create!(
        event: @event, organization: @org_three, type: "co_organizer", role: "collaborator", status: "active"
      )
      Organizations::Organization.create!(
        name: "Pagination Partner #{SecureRandom.hex(4)}",
        organizer_type: "company", category: "conference"
      ).tap do |organization|
        Events::EventOrganization.create!(
          event: @event, organization:, type: "sponsor", role: "sponsor", status: "active"
        )
      end

      get "/events/#{@event.id}/event_organizations?page=2&per_page=1", headers: owner_headers, as: :json

      assert_response :ok
      assert_equal 1, response.parsed_body.dig("data", "collaborators").length
      assert_equal 2, response.parsed_body.dig("pagination", "total_count")
      assert_equal 2, response.parsed_body.dig("pagination", "current_page")
    end
  end
end
