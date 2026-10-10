# frozen_string_literal: true

require "test_helper"

module Organizations
  class OwnerTeamRostersTest < ActionDispatch::IntegrationTest
    setup do
      Rails.stubs(:cache).returns(ActiveSupport::Cache::MemoryStore.new)
      @organization = Organizations::Organization.create!(
        name: "Roster API #{SecureRandom.hex(5)}",
        organizer_type: "individual",
        category: "conference"
      )
      @owner = core_users(:core_admin)
      @active_member = core_users(:support)
      @suspended_member = core_users(:attendee)
      @organization.memberships.create!(user: @owner, role: "owner", status: "active")
      @organization.memberships.create!(user: @active_member, role: "staff", status: "active")
      @organization.memberships.create!(user: @suspended_member, role: "staff", status: "suspended")
      @headers = auth_headers(@owner)
      create_invitation(phone: "+251911999901")
      create_invitation(phone: "+251911999902")
    end

    test "returns separate, independently paginated memberships and pending invitations" do
      get "#{roster_path}?memberships_page=2&memberships_per_page=1&invitations_page=1&invitations_per_page=1",
          headers: @headers,
          as: :json

      assert_response :success, response.body
      data = response.parsed_body.fetch("data")
      memberships = data.fetch("memberships")
      invitations = data.fetch("invitations")

      assert_equal 1, memberships.fetch("data").length
      assert_equal 3, memberships.dig("pagination", "total_count")
      assert_equal 2, memberships.dig("pagination", "current_page")
      assert_equal 1, invitations.fetch("data").length
      assert_equal 2, invitations.dig("pagination", "total_count")
      assert_equal 1, invitations.dig("pagination", "current_page")
      invitation = invitations.fetch("data").first
      assert_equal "pending", invitation.fetch("status")
      assert invitation.fetch("masked_contact").include?("*")
      refute invitation.key?("contact_ciphertext")
      refute invitation.key?("contact_digest")
      refute invitation.key?("claim_token_ciphertext")
      refute invitation.key?("claim_token_digest")
      refute_includes invitations.to_s, "+251911999901"
      refute_includes invitations.to_s, "+251911999902"
    end

    test "requires an organization manager" do
      get roster_path, headers: auth_headers(@active_member), as: :json

      assert_response :forbidden
    end

    private

    def roster_path
      "/organizations/owner/#{@organization.id}/team_roster"
    end

    def create_invitation(phone:)
      result = Organizations::MembershipInvitations::Create.call(
        organization: @organization,
        actor: @owner,
        phone:,
        role: "staff",
        idempotency_key: "org-roster-#{SecureRandom.hex(6)}",
        ip_address: "203.0.113.90"
      )
      assert_predicate result, :success?, result.error&.message
      result.value.record
    end

    def auth_headers(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end
  end
end
