# frozen_string_literal: true

require "test_helper"

module Events
  class EventStaffAssignmentsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    def setup
      @event = events_events(:ready_listing)
      @attendee = core_users(:attendee)
    end

    test "owner can assign staff" do
      assert_difference -> { Events::EventStaffAssignment.count }, 1 do
        post "/events/#{@event.id}/event_staff_assignments",
             params: { event_staff_assignment: { user_id: @attendee.id, role: "staff" } },
             headers: owner_headers,
             as: :json
      end
      assert_response :created
      assignment = Events::EventStaffAssignment.find(JSON.parse(response.body).dig("data", "id"))
      assert_equal @event.id, assignment.event_id
      assert_equal @attendee.id, assignment.user_id
      assert_equal "staff", assignment.role
    end

    test "outsider cannot assign staff" do
      post "/events/#{@event.id}/event_staff_assignments",
           params: { event_staff_assignment: { user_id: @attendee.id, role: "staff" } },
           headers: user_headers,
           as: :json
      assert_response :forbidden
    end

    test "owner can suspend a staff assignment" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "staff", status: "active"
      )
      post "/events/#{@event.id}/event_staff_assignments/#{assignment.id}/suspend",
           headers: owner_headers, as: :json
      assert_response :success
      assert_equal "suspended", assignment.reload.status
    end

    test "owner can revoke a staff assignment" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "staff", status: "active"
      )
      post "/events/#{@event.id}/event_staff_assignments/#{assignment.id}/revoke",
           headers: owner_headers, as: :json
      assert_response :success
      assert_equal "revoked", assignment.reload.status
    end

    test "owner can activate a suspended staff assignment" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "staff", status: "suspended"
      )
      post "/events/#{@event.id}/event_staff_assignments/#{assignment.id}/activate",
           headers: owner_headers, as: :json
      assert_response :success
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

    test "update cannot change status or type through the request body" do
      assignment = Events::EventStaffAssignment.create!(
        event: @event, user: @attendee, organization: @event.organization, role: "staff", status: "active"
      )
      patch "/events/#{@event.id}/event_staff_assignments/#{assignment.id}",
            params: { event_staff_assignment: { role: "scanner", status: "revoked" } },
            headers: owner_headers, as: :json
      assert_response :ok
      assignment.reload
      assert_equal "staff", assignment.role
      assert_equal "active", assignment.status
    end
  end
end
