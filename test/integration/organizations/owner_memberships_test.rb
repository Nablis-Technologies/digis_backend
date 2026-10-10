require "test_helper"

class OrganizationsOwnerMembershipsTest < ActionDispatch::IntegrationTest
  include Core::AuthTestHelpers
  include Core::AuditTestHelpers
  include ActiveJob::TestHelper

  setup do
    @owner = core_users(:core_admin)
    @non_owner = core_users(:attendee)
    @target_user = core_users(:support)
    @org = Organizations::Organization.create!(name: "Owner Test Org #{SecureRandom.hex(4)}", organizer_type: "individual", category: "conference")
    @org.memberships.create!(user: @owner, role: :owner)
    @owner_headers = { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(@owner))}" }
    @non_owner_headers = { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(@non_owner))}" }
  end

  def create_member!(role: "staff")
    @org.memberships.create!(user: @target_user, role: role)
  end

  # ===== Unauthenticated =====

  test "index requires authentication" do
    get "/organizations/owner/#{@org.id}/memberships", as: :json
    assert_response :unauthorized
  end

  test "show requires authentication" do
    member = create_member!
    get "/organizations/owner/#{@org.id}/memberships/#{member.id}", as: :json
    assert_response :unauthorized
  end

  test "update requires authentication" do
    member = create_member!
    patch "/organizations/owner/#{@org.id}/memberships/#{member.id}",
          params: { membership: { role: "staff" } }, as: :json
    assert_response :unauthorized
  end

  test "destroy requires authentication" do
    member = create_member!
    delete "/organizations/owner/#{@org.id}/memberships/#{member.id}", as: :json
    assert_response :unauthorized
  end

  # ===== Non-owner authenticated =====

  test "index returns 403 for non-owner" do
    get "/organizations/owner/#{@org.id}/memberships", headers: @non_owner_headers, as: :json
    assert_response :forbidden
  end

  test "show returns 403 for non-owner" do
    member = create_member!
    get "/organizations/owner/#{@org.id}/memberships/#{member.id}", headers: @non_owner_headers, as: :json
    assert_response :forbidden
  end

  test "update returns 403 for non-owner" do
    member = create_member!
    patch "/organizations/owner/#{@org.id}/memberships/#{member.id}",
          params: { membership: { role: "staff" } },
          headers: @non_owner_headers, as: :json
    assert_response :forbidden
  end

  test "destroy returns 403 for non-owner" do
    member = create_member!
    delete "/organizations/owner/#{@org.id}/memberships/#{member.id}",
           headers: @non_owner_headers, as: :json
    assert_response :forbidden
  end

  # ===== Owner authenticated - CRUD =====

  test "index returns memberships for owner" do
    get "/organizations/owner/#{@org.id}/memberships", headers: @owner_headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert data.is_a?(Array)
    assert data.length >= 1
  end

  test "show returns membership for owner" do
    member = create_member!
    get "/organizations/owner/#{@org.id}/memberships/#{member.id}", headers: @owner_headers, as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert_equal member.id, data["id"]
    assert data.key?("user")
  end

  test "update changes membership role" do
    member = create_member!
    patch "/organizations/owner/#{@org.id}/memberships/#{member.id}",
          params: { membership: { role: "admin" } },
          headers: @owner_headers, as: :json
    assert_response :success
    assert_equal "admin", member.reload.role
  end

  test "destroy removes a member" do
    member = create_member!
    assert_difference("@org.memberships.count", -1) do
      delete "/organizations/owner/#{@org.id}/memberships/#{member.id}",
             headers: @owner_headers, as: :json
    end
    assert_response :success
  end

  # ===== Owner role guard =====

  test "update to owner role returns 422" do
    member = create_member!
    patch "/organizations/owner/#{@org.id}/memberships/#{member.id}",
          params: { membership: { role: "owner" } },
          headers: @owner_headers, as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert body.key?("error")
  end

  # ===== Self-destruction guard =====

  test "owner cannot destroy their own membership" do
    owner_membership = @org.memberships.find_by!(user: @owner)
    assert_no_difference("@org.memberships.count") do
      delete "/organizations/owner/#{@org.id}/memberships/#{owner_membership.id}",
             headers: @owner_headers, as: :json
    end
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal I18n.t("membership.errors.transfer_ownership_required"), body["error"]
  end

  test "owner can destroy a non-owner membership" do
    member = create_member!
    assert_difference("@org.memberships.count", -1) do
      delete "/organizations/owner/#{@org.id}/memberships/#{member.id}",
             headers: @owner_headers, as: :json
    end
    assert_response :success
  end

  # ===== Auditing =====

  test "update logs an audit" do
    member = create_member!
    perform_enqueued_jobs do
      patch "/organizations/owner/#{@org.id}/memberships/#{member.id}",
            params: { membership: { role: "admin" } },
            headers: @owner_headers, as: :json
    end
    assert_response :success
    assert_audit_logged(action: "update", auditable: member, actor: @owner)
  end

  test "destroy logs an audit" do
    member = create_member!
    perform_enqueued_jobs do
      delete "/organizations/owner/#{@org.id}/memberships/#{member.id}",
             headers: @owner_headers, as: :json
    end
    assert_response :success
    assert_audit_logged(action: "destroy", auditable: member, actor: @owner)
  end
end
