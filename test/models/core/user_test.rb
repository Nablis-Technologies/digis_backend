require "test_helper"

class CoreUserTest < ActiveSupport::TestCase
  test "requires either email or phone" do
    user = Core::User.new(password: "password123", password_confirmation: "password123")

    assert_not user.valid?
    assert_includes user.errors[:base], "Either email or phone must be provided"
  end

  test "normalizes email before validation" do
    user = Core::User.new(
      email: "  MIXED@Example.COM ",
      password: "password123",
      password_confirmation: "password123"
    )

    user.valid?

    assert_equal "mixed@example.com", user.email
  end

  test "permission helpers reflect active assigned permissions" do
    admin = core_users(:core_admin)

    assert admin.has_role?("CORE_ADMIN")
    assert admin.has_permission?("role.index")
    assert admin.has_all_permissions?("role.index", "permission.create")
    assert admin.has_any_permission?("permission.create", "user.index")
    assert_equal admin.can?("role.index"), admin.has_permission?("role.index")
  end

  test "super admins bypass explicit permission checks" do
    user = core_users(:super_admin)

    assert user.super_admin?
    assert user.has_permission?("anything.at.all")
  end
end
