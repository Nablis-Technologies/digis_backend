require "test_helper"

class OrganizationsOrganizationsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test skip_authorization: true,
                check_attributes: {
                  index: %w[id name slug description created_at profile_url],
                  show: %w[id name slug description social_links created_at profile_url follower_count]
                }

  test "scope returns all for super_admin" do
    scope = Organizations::OrganizationPolicy::Scope.new(core_users(:super_admin), Organizations::Organization)
    assert_includes scope.resolve, organizations_organizations(:one)
  end

  test "scope returns all for non-admin" do
    scope = Organizations::OrganizationPolicy::Scope.new(core_users(:attendee), Organizations::Organization)
    assert_includes scope.resolve, organizations_organizations(:one)
  end

  test "index supports search by name" do
    get "/organizations/organizations?q[name_cont]=Digis", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    assert data.all? { |o| o["name"].include?("Digis") }
  end

  test "index orders by name ascending" do
    get "/organizations/organizations?order_by=name&order_direction=asc", as: :json
    assert_response :success
    data = JSON.parse(response.body).dig("data")
    names = data.map { |o| o["name"] }
    assert_equal names.sort, names
  end
end
