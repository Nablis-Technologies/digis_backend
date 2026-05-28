require "test_helper"

class OrganizationsMembershipsTest < ActionDispatch::IntegrationTest
  include Core::ResourceTest

  resource_test

  test "scope returns all for super_admin" do
    scope = Organizations::MembershipPolicy::Scope.new(core_users(:super_admin), Organizations::Membership)
    assert_includes scope.resolve, organizations_organizations(:one).memberships.first
  end

  test "scope returns only owned org memberships for non-admin" do
    scope = Organizations::MembershipPolicy::Scope.new(core_users(:attendee), Organizations::Membership)
    assert_not_includes scope.resolve, organizations_organizations(:one).memberships.first
  end
end
