require "test_helper"

class OrganizationsOrganizationsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test create_params: -> { { organization: { name: "New Org" } } },
               update_params: ->(record) { { organization: { name: "Updated Org" } } }

  test "scope returns all for super_admin" do
    scope = Organizations::OrganizationPolicy::Scope.new(core_users(:super_admin), Organizations::Organization)
    assert_includes scope.resolve, organizations_organizations(:one)
  end

  test "scope returns only owned orgs for non-admin" do
    scope = Organizations::OrganizationPolicy::Scope.new(core_users(:attendee), Organizations::Organization)
    assert_not_includes scope.resolve, organizations_organizations(:one)
  end

  test "non-owner index returns empty list" do
    user = core_users(:attendee)
    get "/organizations/organizations", headers: token_headers_for(user), as: :json
    assert_response :success
    assert_equal [], JSON.parse(response.body).dig("data")
  end

  test "after_create_hook creates owner membership" do
    user = core_users(:attendee)
    post "/organizations/organizations",
         params: { organization: { name: "My Org" } },
         headers: token_headers_for(user), as: :json
    assert_response :created
    org = Organizations::Organization.find(JSON.parse(response.body).dig("data", "id"))
    assert_equal user.id, org.owner.id
  end
end
