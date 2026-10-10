# frozen_string_literal: true

require "test_helper"

module Events
  class StaffRostersTest < ActionDispatch::IntegrationTest
    setup do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      @event = events_events(:ready_listing)
      @owner = core_users(:core_admin)
      @staff = core_users(:attendee)
      @contractor = core_users(:support)
      @outsider = core_users(:super_admin)
      Events::EventStaffAssignment.create!(
        event: @event, organization: @event.organization, user: @staff, role: "staff", status: "active"
      )
      Events::EventStaffAssignment.create!(
        event: @event, organization: @event.organization, user: @contractor, role: "contractor", status: "suspended"
      )
      Events::EventStaffAssignment.create!(
        event: @event, organization: @event.organization, user: @outsider, role: "scanner", status: "active"
      )
      @headers = auth_headers(@owner)
      create_invitation(phone: "+251911999911")
      create_invitation(phone: "+251911999912")
    end

    test "returns non-scanner assignments and pending invitations with independent pagination" do
      get "#{roster_path}?assignments_page=2&assignments_per_page=1&invitations_page=1&invitations_per_page=2",
          headers: @headers,
          as: :json

      assert_response :success, response.body
      data = response.parsed_body.fetch("data")
      assignments = data.fetch("assignments")
      invitations = data.fetch("invitations")

      assert_equal 1, assignments.fetch("data").length
      assert_equal 2, assignments.dig("pagination", "total_count")
      assert_equal 2, assignments.dig("pagination", "current_page")
      assert assignments.fetch("data").all? { |assignment| assignment.fetch("role") != "scanner" }
      assert_equal 2, invitations.fetch("data").length
      assert_equal 2, invitations.dig("pagination", "total_count")
      invitation = invitations.fetch("data").first
      assert_equal "pending", invitation.fetch("status")
      assert invitation.fetch("masked_contact").include?("*")
      refute invitation.key?("contact_ciphertext")
      refute invitation.key?("contact_digest")
      refute invitation.key?("claim_token_ciphertext")
      refute invitation.key?("claim_token_digest")
      refute_includes invitations.to_s, "+251911999911"
      refute_includes invitations.to_s, "+251911999912"
    end

    test "requires authority to manage the event staff roster" do
      get roster_path, headers: auth_headers(core_users(:attendee)), as: :json

      assert_response :forbidden
    end

    private

    def roster_path
      "/events/#{@event.id}/staff_roster"
    end

    def create_invitation(phone:)
      result = Events::StaffInvitations::Create.call(
        event: @event,
        actor: @owner,
        phone:,
        role: "staff",
        idempotency_key: "event-roster-#{SecureRandom.hex(6)}",
        ip_address: "203.0.113.91"
      )
      assert_predicate result, :success?, result.error&.message
      result.value.record
    end

    def auth_headers(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end
  end
end
