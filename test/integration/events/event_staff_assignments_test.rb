# frozen_string_literal: true

require "test_helper"

module Events
  class EventStaffAssignmentsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    def setup
      @event = events_events(:ready_listing)
      @attendee = core_users(:attendee)
    end

    test "owner can list staff assignments" do
      Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "staff", status: "active"
      )
      get "/events/#{@event.id}/event_staff_assignments", headers: owner_headers, as: :json
      assert_response :ok
      assert JSON.parse(response.body)["data"].is_a?(Array)
    end

    test "staff assignment responses include safe user and organization summaries" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "staff", status: "active"
      )

      get "/events/#{@event.id}/event_staff_assignments", headers: owner_headers, as: :json

      assert_response :ok
      payload = response.parsed_body.fetch("data").find { |item| item.fetch("id") == assignment.id }
      assert_equal @attendee.email, payload.dig("user", "email")
      assert_equal @attendee.phone, payload.dig("user", "phone")
      assert_equal @event.organization.name, payload.dig("organization", "name")
      refute payload.key?("password_digest")
    end

    test "owner can suspend a staff assignment" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "staff", status: "active"
      )
      post "/events/#{@event.id}/event_staff_assignments/#{assignment.id}/suspend",
           headers: owner_headers, as: :json
      assert_response :success
      assert_equal I18n.t("event_staff_assignment.success.suspend"), JSON.parse(response.body)["message"]
      assert_equal "suspended", assignment.reload.status
    end

    test "owner can revoke a staff assignment" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "staff", status: "active"
      )
      post "/events/#{@event.id}/event_staff_assignments/#{assignment.id}/revoke",
           headers: owner_headers.merge("Idempotency-Key" => "staff-revoke-#{assignment.id}"), as: :json
      assert_response :success
      assert_equal I18n.t("event_staff_assignment.success.revoke"), JSON.parse(response.body)["message"]
      assert_equal "revoked", assignment.reload.status
    end

    test "scanner revoke requires idempotency and replays without duplicate outbox events" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "scanner", status: "active"
      )
      post "/events/#{@event.id}/event_staff_assignments/#{assignment.id}/revoke",
           headers: owner_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
      assert_equal "active", assignment.reload.status

      headers = owner_headers.merge("Idempotency-Key" => "scanner-revoke-#{assignment.id}")
      Prosopite.pause do
        assert_difference -> {
          Core::OutboxEvent.where(
            event_type: "events.staff_assignment.revoked", aggregate_id: assignment.id
          ).count
        }, 1 do
          2.times do
            post "/events/#{@event.id}/event_staff_assignments/#{assignment.id}/revoke", headers:, as: :json
            assert_response :success
          end
        end
      end
      assert_equal "revoked", assignment.reload.status
    end

    test "owner can activate a suspended staff assignment" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "staff", status: "suspended"
      )
      post "/events/#{@event.id}/event_staff_assignments/#{assignment.id}/activate",
           headers: owner_headers, as: :json
      assert_response :success
      assert_equal I18n.t("event_staff_assignment.success.activate"), JSON.parse(response.body)["message"]
      assert_equal "active", assignment.reload.status
    end

    test "outsider cannot activate a staff assignment" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "staff", status: "suspended"
      )
      post "/events/#{@event.id}/event_staff_assignments/#{assignment.id}/activate",
           headers: user_headers, as: :json
      assert_response :forbidden
      assert_equal "suspended", assignment.reload.status
    end

    test "owner can change a staff assignment role" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "staff", status: "active"
      )
      post "/events/#{@event.id}/event_staff_assignments/#{assignment.id}/change_role",
           params: { role: "scanner" },
           headers: owner_headers, as: :json
      assert_response :success
      assert_equal I18n.t("event_staff_assignment.success.change_role"), JSON.parse(response.body)["message"]
      assert_equal "scanner", assignment.reload.role
    end

    test "adding a collaborator org does not grant access to its members" do
      org_three = organizations_organizations(:three)
      post "/events/#{@event.id}/event_organizations",
           params: { event_organization: { organization_id: org_three.id, type: "co_organizer", role: "collaborator", status: "active" } },
           headers: owner_headers, as: :json
      assert_response :created
      assert Events::EventOrganization.exists?(event: @event, organization: org_three)

      org_three_owner = core_users(:support)
      refute Events::AuthorizationResolver.access_granted?(org_three_owner, @event)
    end

    test "generic assignment update is unavailable so user UUIDs cannot bypass invitation claim" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "staff", status: "active"
      )
      patch "/events/#{@event.id}/event_staff_assignments/#{assignment.id}",
            params: {
              event_staff_assignment: {
                user_id: core_users(:support).id,
                organization_id: organizations_organizations(:three).id
              }
            },
            headers: owner_headers, as: :json
      assert_response :not_found
      assignment.reload
      assert_equal @attendee.id, assignment.user_id
      assert_equal @event.organization_id, assignment.organization_id
      assert_equal "active", assignment.status
    end

    test "physical assignment deletion is unavailable in favor of audited revoke" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "scanner", status: "active"
      )

      delete "/events/#{@event.id}/event_staff_assignments/#{assignment.id}",
             headers: owner_headers,
             as: :json

      assert_response :not_found
      assert_equal "active", assignment.reload.status
    end
  end
end
