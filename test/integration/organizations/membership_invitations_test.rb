# frozen_string_literal: true

require "test_helper"

module Organizations
  class MembershipInvitationsTest < ActionDispatch::IntegrationTest
    setup do
      @organization = Organizations::Organization.create!(
        name: "Invitation API #{SecureRandom.hex(5)}",
        organizer_type: "individual",
        category: "conference"
      )
      @owner = core_users(:core_admin)
      @invitee = core_users(:support)
      @organization.memberships.create!(user: @owner, role: "owner")
      @owner_headers = auth_headers(@owner)
      @invitee_headers = auth_headers(@invitee)
    end

    test "creation requires an authenticated manager and idempotency key" do
      post invitations_path, params: create_params, as: :json
      assert_response :unauthorized

      post invitations_path, params: create_params, headers: @owner_headers, as: :json
      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "creates a pending invitation without granting access and returns a private fragment link" do
      user_count = Core::User.count
      membership_count = @organization.memberships.count

      post invitations_path,
           params: create_params,
           headers: idempotent_headers(@owner_headers, "org-invite-create"),
           as: :json

      assert_response :created
      assert_match(/no-store/, response.headers.fetch("Cache-Control"))
      assert_match(/private/, response.headers.fetch("Cache-Control"))
      invitation_json = response.parsed_body.dig("data", "invitation")
      claim_url = response.parsed_body.dig("data", "claim_url")
      invitation = Organizations::MembershipInvitation.find(invitation_json.fetch("id"))

      assert_equal "pending", invitation.status
      assert_equal "admin", invitation.role
      assert_equal user_count, Core::User.count
      assert_equal membership_count, @organization.memberships.count
      assert_equal "+251911000004", invitation.contact_ciphertext
      assert claim_url.end_with?("#token=#{invitation.claim_token_ciphertext}")
      refute_includes claim_url, "?token="
      refute invitation_json.key?("claim_token_ciphertext")
      refute invitation_json.key?("claim_token_digest")
      refute invitation_json.key?("contact_ciphertext")
      refute invitation_json.key?("contact_digest")
      refute_includes invitation_json.to_s, invitation.contact_ciphertext
      assert_equal({ "invitation_id" => invitation.id, "delivery_revision" => 1 }, Core::OutboxEvent.find_by!(
        aggregate_id: invitation.id,
        event_type: "organizations.membership_invitation.delivery_requested"
      ).payload)
    end

    test "replays create safely and rejects duplicate, disabled email, and forbidden roles" do
      headers = idempotent_headers(@owner_headers, "org-invite-idempotent")
      assert_difference -> { Organizations::MembershipInvitation.count }, 1 do
        post invitations_path, params: create_params, headers:, as: :json
        assert_response :created
        first_id = response.parsed_body.dig("data", "invitation", "id")
        post invitations_path, params: create_params, headers:, as: :json
        assert_response :created
        assert_equal first_id, response.parsed_body.dig("data", "invitation", "id")
      end

      post invitations_path,
           params: create_params(phone: "+251911000004"),
           headers: idempotent_headers(@owner_headers, "org-invite-duplicate"),
           as: :json
      assert_response :conflict
      assert_equal "invitation_already_pending", response.parsed_body.fetch("code")

      post invitations_path,
           params: { membership_invitation: { email: "later@example.com", role: "staff" } },
           headers: idempotent_headers(@owner_headers, "org-invite-email"),
           as: :json
      assert_response :unprocessable_entity
      assert_equal "invitation_channel_not_enabled", response.parsed_body.fetch("code")

      post invitations_path,
           params: { membership_invitation: { phone: "+251911000004", role: "owner" } },
           headers: idempotent_headers(@owner_headers, "org-invite-owner-role"),
           as: :json
      assert_response :unprocessable_entity
      assert_equal "invalid_role", response.parsed_body.fetch("code")
    end

    test "resend rotates the one-time link and revoke prevents claim" do
      invitation = create_invitation
      original_token = invitation.claim_token_ciphertext
      original_expiry = invitation.expires_at

      post "#{invitations_path}/#{invitation.id}/resend",
           headers: idempotent_headers(@owner_headers, "org-invite-resend"),
           as: :json
      assert_response :success
      new_token = invitation.reload.claim_token_ciphertext
      refute_equal original_token, new_token
      assert_equal original_expiry, invitation.expires_at
      assert response.parsed_body.dig("data", "claim_url").end_with?("#token=#{new_token}")

      post "#{invitations_path}/#{invitation.id}/revoke",
           headers: idempotent_headers(@owner_headers, "org-invite-revoke"),
           as: :json
      assert_response :success
      assert_equal "revoked", invitation.reload.status
      assert_nil invitation.claim_token_ciphertext

      post claim_path,
           params: { token: new_token },
           headers: idempotent_headers(@invitee_headers, "org-invite-claim-revoked"),
           as: :json
      assert_response :unauthorized
      assert_equal "membership_invitation_claim_invalid", response.parsed_body.fetch("code")
    end

    test "claim requires verified matching phone and creates only scoped membership" do
      invitation = create_invitation
      existing_roles = @invitee.roles.pluck(:id)
      existing_memberships = Organizations::Membership.where(user: @invitee).count
      token = invitation.claim_token_ciphertext

      post claim_path,
           params: { token: },
           headers: idempotent_headers(@owner_headers, "org-invite-wrong-phone"),
           as: :json
      assert_response :forbidden
      assert_equal "invitation_contact_mismatch", response.parsed_body.fetch("code")
      assert_equal "pending", invitation.reload.status

      post claim_path,
           params: { token: },
           headers: idempotent_headers(@invitee_headers, "org-invite-claim"),
           as: :json
      assert_response :success
      membership = @organization.memberships.find_by!(user: @invitee)
      assert_equal "admin", membership.role
      assert_equal "active", membership.status
      assert_equal existing_roles, @invitee.roles.pluck(:id)
      assert_equal existing_memberships + 1, Organizations::Membership.where(user: @invitee).count
      assert_equal "accepted", invitation.reload.status
      refute response.body.include?(token)

      post claim_path,
           params: { token: },
           headers: idempotent_headers(@invitee_headers, "org-invite-claim"),
           as: :json
      assert_response :success
      assert_equal 1, @organization.memberships.where(user: @invitee).count
    end

    test "preview exposes only authenticated invite context before explicit acceptance" do
      invitation = create_invitation
      token = invitation.claim_token_ciphertext
      membership_count = @organization.memberships.count

      post "/organizations/membership_invitations/preview",
           params: { token: },
           headers: @invitee_headers,
           as: :json

      assert_response :success
      assert_match(/no-store/, response.headers.fetch("Cache-Control"))
      data = response.parsed_body.fetch("data")
      assert_equal @organization.id, data.dig("organization", "id")
      assert_equal @organization.name, data.dig("organization", "name")
      assert_equal "admin", data.fetch("role")
      assert_equal @owner.email, data.dig("inviter", "email")
      assert data.fetch("masked_contact").include?("*")
      refute_includes response.body, token
      refute_includes response.body, @invitee.phone
      assert_equal "pending", invitation.reload.status
      assert_equal membership_count, @organization.memberships.count

      post "/organizations/membership_invitations/preview",
           params: { token: },
           headers: @owner_headers,
           as: :json
      assert_response :forbidden
      assert_equal "invitation_contact_mismatch", response.parsed_body.fetch("code")
    end

    test "preview fails closed when the encrypted invitation contact cannot be decrypted" do
      invitation = create_invitation
      connection = ActiveRecord::Base.connection
      connection.execute(
        "UPDATE organizations_membership_invitations " \
        "SET contact_ciphertext = #{connection.quote("not-encrypted")} " \
        "WHERE id = #{connection.quote(invitation.id)}"
      )

      post "/organizations/membership_invitations/preview",
           params: { token: invitation.claim_token_ciphertext },
           headers: @invitee_headers,
           as: :json

      assert_response :unauthorized
      assert_equal "membership_invitation_claim_invalid", response.parsed_body.fetch("code")
    end

    test "direct UUID membership creation is retired" do
      post "/organizations/owner/#{@organization.id}/memberships",
           params: { membership: { user_id: @invitee.id, role: "staff" } },
           headers: idempotent_headers(@owner_headers, "legacy-membership-create"),
           as: :json
      assert_response :not_found
      assert_empty @organization.memberships.where(user: @invitee)
    end

    private

    def invitations_path
      "/organizations/owner/#{@organization.id}/membership_invitations"
    end

    def claim_path
      "/organizations/membership_invitations/claim"
    end

    def create_params(phone: @invitee.phone)
      { membership_invitation: { phone:, role: "admin" } }
    end

    def create_invitation
      post invitations_path,
           params: create_params,
           headers: idempotent_headers(@owner_headers, "org-invite-helper-#{SecureRandom.hex(6)}"),
           as: :json
      assert_response :created
      Organizations::MembershipInvitation.find(response.parsed_body.dig("data", "invitation", "id"))
    end

    def auth_headers(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end

    def idempotent_headers(headers, key)
      headers.merge("Idempotency-Key" => key)
    end
  end
end
