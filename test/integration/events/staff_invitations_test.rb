# frozen_string_literal: true

require "test_helper"

module Events
  class StaffInvitationsTest < ActionDispatch::IntegrationTest
    setup do
      @event = events_events(:ready_listing)
      @owner = core_users(:core_admin)
      @invitee = core_users(:attendee)
      @owner_headers = auth_headers(@owner)
      @invitee_headers = auth_headers(@invitee)
    end

    test "event owner creates a pending event-scoped invitation with no assignment" do
      assignment_expires_at = 2.days.from_now.change(usec: 0)
      assignment_count = @event.event_staff_assignments.count

      post invitations_path,
           params: { staff_invitation: {
             phone: @invitee.phone,
             role: "staff",
             assignment_expires_at: assignment_expires_at.iso8601
           } },
           headers: idempotent_headers(@owner_headers, "event-invite-create"),
           as: :json

      assert_response :created
      assert_match(/no-store/, response.headers.fetch("Cache-Control"))
      invitation_json = response.parsed_body.dig("data", "invitation")
      claim_url = response.parsed_body.dig("data", "claim_url")
      invitation = Events::StaffInvitation.find(invitation_json.fetch("id"))

      assert_equal "pending", invitation.status
      assert_equal assignment_expires_at.to_i, invitation.assignment_expires_at.to_i
      assert_equal 7.days.from_now.to_date, invitation.expires_at.to_date
      assert_equal assignment_count, @event.event_staff_assignments.count
      assert claim_url.end_with?("#token=#{invitation.claim_token_ciphertext}")
      refute_includes claim_url, "?token="
      refute invitation_json.key?("claim_token_ciphertext")
      refute invitation_json.key?("claim_token_digest")
      refute invitation_json.key?("contact_ciphertext")
    end

    test "claim creates only an event assignment and replay is idempotent" do
      invitation = create_invitation
      token = invitation.claim_token_ciphertext
      initial_memberships = Organizations::Membership.where(user: @invitee).count
      global_roles = @invitee.roles.pluck(:id)

      post claim_path,
           params: { token: },
           headers: idempotent_headers(@invitee_headers, "event-invite-claim"),
           as: :json

      assert_response :success
      assignment = @event.event_staff_assignments.find_by!(user: @invitee, role: "staff")
      assert_equal @event.organization_id, assignment.organization_id
      assert_equal "accepted", invitation.reload.status
      assert_equal initial_memberships, Organizations::Membership.where(user: @invitee).count
      assert_equal global_roles, @invitee.roles.pluck(:id)
      refute_includes response.body, token

      post claim_path,
           params: { token: },
           headers: idempotent_headers(@invitee_headers, "event-invite-claim"),
           as: :json
      assert_response :success
      assert_equal 1, @event.event_staff_assignments.where(user: @invitee, role: "staff").count
    end

    test "preview exposes event and role to the verified invitee without accepting" do
      invitation = create_invitation
      token = invitation.claim_token_ciphertext
      assignment_count = @event.event_staff_assignments.count

      post "/events/staff_invitations/preview",
           params: { token: },
           headers: @invitee_headers,
           as: :json

      assert_response :success
      assert_match(/no-store/, response.headers.fetch("Cache-Control"))
      data = response.parsed_body.fetch("data")
      assert_equal @event.id, data.dig("event", "id")
      assert_equal @event.title, data.dig("event", "title")
      assert_equal "staff", data.fetch("role")
      assert_equal @owner.email, data.dig("inviter", "email")
      assert data.fetch("masked_contact").include?("*")
      refute_includes response.body, token
      refute_includes response.body, @invitee.phone
      assert_equal "pending", invitation.reload.status
      assert_equal assignment_count, @event.event_staff_assignments.count

      post "/events/staff_invitations/preview",
           params: { token: },
           headers: idempotent_headers(auth_headers(core_users(:support)), "wrong-phone-preview"),
           as: :json
      assert_response :forbidden
      assert_equal "invitation_contact_mismatch", response.parsed_body.fetch("code")
    end

    test "rejects missing idempotency, scanner role, email, and unauthorized creation" do
      post invitations_path,
           params: { staff_invitation: { phone: @invitee.phone, role: "staff" } },
           headers: @owner_headers,
           as: :json
      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")

      post invitations_path,
           params: { staff_invitation: { phone: @invitee.phone, role: "scanner" } },
           headers: idempotent_headers(@owner_headers, "event-invite-scanner"),
           as: :json
      assert_response :unprocessable_entity
      assert_equal "invalid_role", response.parsed_body.fetch("code")

      post invitations_path,
           params: { staff_invitation: { email: "future@example.com", role: "staff" } },
           headers: idempotent_headers(@owner_headers, "event-invite-email"),
           as: :json
      assert_response :unprocessable_entity
      assert_equal "invitation_channel_not_enabled", response.parsed_body.fetch("code")

      post invitations_path,
           params: { staff_invitation: { phone: @invitee.phone, role: "staff" } },
           headers: idempotent_headers(@invitee_headers, "event-invite-forbidden"),
           as: :json
      assert_response :forbidden
      assert_empty Events::StaffInvitation.where(event: @event)
    end

    test "resends by rotating capability, then revokes pending invitation" do
      invitation = create_invitation(phone: "+251911999801")
      initial_expiry = invitation.expires_at
      old_token = invitation.claim_token_ciphertext

      post "#{invitations_path}/#{invitation.id}/resend",
           headers: idempotent_headers(@owner_headers, "event-invite-resend"),
           as: :json
      assert_response :success
      new_token = invitation.reload.claim_token_ciphertext
      refute_equal old_token, new_token
      assert_equal initial_expiry, invitation.expires_at

      post "#{invitations_path}/#{invitation.id}/revoke",
           headers: idempotent_headers(@owner_headers, "event-invite-revoke"),
           as: :json
      assert_response :success
      assert_equal "revoked", invitation.reload.status
      assert_nil invitation.claim_token_ciphertext
    end

    test "direct UUID event assignment creation is retired" do
      post "/events/#{@event.id}/event_staff_assignments",
           params: { event_staff_assignment: { user_id: @invitee.id, role: "staff" } },
           headers: idempotent_headers(@owner_headers, "legacy-event-assignment-create"),
           as: :json
      assert_response :not_found
      assert_empty @event.event_staff_assignments.where(user: @invitee)
    end

    private

    def invitations_path
      "/events/#{@event.id}/staff_invitations"
    end

    def claim_path
      "/events/staff_invitations/claim"
    end

    def create_invitation(phone: @invitee.phone)
      post invitations_path,
           params: { staff_invitation: { phone:, role: "staff" } },
           headers: idempotent_headers(@owner_headers, "event-invite-helper-#{SecureRandom.hex(6)}"),
           as: :json
      assert_response :created
      Events::StaffInvitation.find(response.parsed_body.dig("data", "invitation", "id"))
    end

    def auth_headers(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end

    def idempotent_headers(headers, key)
      headers.merge("Idempotency-Key" => key)
    end
  end
end
