require "test_helper"

class Organizations::MembershipTest < ActiveSupport::TestCase
  test "belongs_to user" do
    assert Organizations::Membership.reflect_on_association(:user).macro == :belongs_to
  end

  test "belongs_to organization" do
    assert Organizations::Membership.reflect_on_association(:organization).macro == :belongs_to
  end

  test "validates presence of role" do
    assert validate_presence_of(:role).matches?(Organizations::Membership.new)
  end

  test "enforces one owner per organization at DB level" do
    org = Organizations::Organization.create!(name: "Test Org", organizer_type: "individual", category: "conference")
    org.memberships.create!(user: core_users(:super_admin), role: :owner)

    assert_raises ActiveRecord::RecordNotUnique do
      org.memberships.create!(user: core_users(:core_admin), role: :owner)
    end
  end

  test "allows multiple non-owner memberships" do
    org = Organizations::Organization.create!(name: "Test Org", organizer_type: "individual", category: "conference")
    org.memberships.create!(user: core_users(:super_admin), role: :owner)
    org.memberships.create!(user: core_users(:core_admin), role: :staff)
    org.memberships.create!(user: core_users(:attendee), role: :staff)

    assert_equal 3, org.memberships.count
  end

  test "ransackable_attributes returns safe attributes" do
    expected = %w[id user_id organization_id role status created_at updated_at]
    assert_equal expected, Organizations::Membership.ransackable_attributes
  end

  test "ransackable_associations returns user and organization" do
    assert_equal %w[user organization], Organizations::Membership.ransackable_associations
  end
end
