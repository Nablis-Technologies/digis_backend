require "test_helper"

class AdminOrganizationMembershipsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test model: Organizations::Membership,
                policy_class: Admin::MembershipPolicy,
                controller: Admin::OrganizationMembershipsController,
                parent_fixture: :one,
                fixture_keys: %i[super_admin core_admin support attendee],
                path: -> { "/admin/organizations/#{organizations_organizations(:one).id}/memberships" },
                create_params: -> {
                  target = core_users(:attendee)
                  { membership: { user_id: target.id, role: "admin" } }
                },
                update_params: ->(record) { { membership: { role: "member" } } },
                check_attributes: {
                  show: %w[id role created_at],
                  index: %w[id role created_at]
                },
                index: {
                  pagination: { per_page: 2 },
                  ordering: { order_by: "created_at", direction: "desc" }
                }

  # ── Owner-role rejection ─────────────────────────
  test "create rejects owner role" do
    target = core_users(:attendee)
    org = organizations_organizations(:one)

    post "/admin/organizations/#{org.id}/memberships",
         params: { membership: { user_id: target.id, role: "owner" } },
         headers: admin_headers, as: :json
    assert_response :unprocessable_entity
  end

  test "update rejects owner role" do
    org = organizations_organizations(:one)
    membership = org.memberships.where.not(role: :owner).first
    membership ||= org.memberships.create!(user: core_users(:attendee), role: :member)

    patch "/admin/organizations/#{org.id}/memberships/#{membership.id}",
          params: { membership: { role: "owner" } },
          headers: admin_headers, as: :json
    assert_response :unprocessable_entity
  end

  # ── Scope tests ──────────────────────────────────
  test "scope returns all memberships for super_admin" do
    scope = Admin::MembershipPolicy::Scope.new(core_users(:super_admin), Organizations::Membership)
    assert_includes scope.resolve, organizations_memberships(:owner_one)
  end

  test "scope returns all memberships for core_admin" do
    scope = Admin::MembershipPolicy::Scope.new(core_users(:core_admin), Organizations::Membership)
    assert_includes scope.resolve, organizations_memberships(:owner_one)
  end

  test "scope returns no memberships for attendee" do
    scope = Admin::MembershipPolicy::Scope.new(core_users(:attendee), Organizations::Membership)
    assert_not_includes scope.resolve, organizations_memberships(:owner_one)
  end

  test "index returns memberships for support readers" do
    org = organizations_organizations(:one)

    get "/admin/organizations/#{org.id}/memberships",
        headers: token_headers_for(core_users(:support)), as: :json

    assert_response :success
    data = JSON.parse(response.body).fetch("data")
    assert data.any?, "expected support readers to receive membership rows"
  end

  # ── Forbidden actions per role matrix ────────────
  test "update membership is forbidden for support" do
    org = organizations_organizations(:one)
    membership = org.memberships.where.not(role: :owner).first
    membership ||= org.memberships.create!(user: core_users(:attendee), role: :member)

    patch "/admin/organizations/#{org.id}/memberships/#{membership.id}",
          params: { membership: { role: "member" } },
          headers: token_headers_for(core_users(:support)), as: :json
    assert_response :forbidden
  end
end
