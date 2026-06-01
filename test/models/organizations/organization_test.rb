require "test_helper"

class Organizations::OrganizationTest < ActiveSupport::TestCase
  include Core::SlugableTest
  test_slugable

  test "validates presence of name" do
    assert validate_presence_of(:name).matches?(Organizations::Organization.new)
  end

  test "validates uniqueness of slug" do
    Organizations::Organization.create!(name: "Test Org")
    assert validate_uniqueness_of(:slug).matches?(Organizations::Organization.new(name: "Test Org 2"))
  end

  test "has_many memberships" do
    assert Organizations::Organization.reflect_on_association(:memberships).macro == :has_many
  end

  test "has_one owner_membership" do
    assert Organizations::Organization.reflect_on_association(:owner_membership).macro == :has_one
  end

  test "owner returns user from owner_membership" do
    user = core_users(:super_admin)
    org = Organizations::Organization.create!(name: "Test Org")
    org.memberships.create!(user: user, role: :owner)

    assert_equal user, org.owner
  end

  test "owner returns nil when no owner membership" do
    org = Organizations::Organization.create!(name: "Test Org")
    assert_nil org.owner
  end

  test "ransackable_attributes returns safe attributes" do
    expected = %w[name slug description created_at]
    assert_equal expected, Organizations::Organization.ransackable_attributes
  end

  test "ransackable_associations returns memberships" do
    assert_equal %w[memberships], Organizations::Organization.ransackable_associations
  end
end
