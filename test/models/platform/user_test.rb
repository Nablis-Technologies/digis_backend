require "test_helper"

class PlatformUserTest < ActiveSupport::TestCase
  test "requires either email or phone" do
    user = Platform::User.new(password: "password123", password_confirmation: "password123")

    assert_not user.valid?
    assert_includes user.errors[:base], "Either email or phone must be provided"
  end

  test "normalizes email before validation" do
    user = Platform::User.new(
      email: "  MIXED@Example.COM ",
      password: "password123",
      password_confirmation: "password123"
    )

    user.valid?

    assert_equal "mixed@example.com", user.email
  end

  test "permission helpers reflect active assigned permissions" do
    admin = platform_users(:platform_admin)

    assert admin.has_role?("PLATFORM_ADMIN")
    assert admin.has_permission?("roles.index")
    assert admin.has_all_permissions?("roles.index", "permissions.manage")
    assert admin.has_any_permission?("permissions.manage", "users.index")
    assert_equal admin.can?("roles.index"), admin.has_permission?("roles.index")
  end

  test "super admins bypass explicit permission checks" do
    user = platform_users(:super_admin)

    assert user.super_admin?
    assert user.has_permission?("anything.at.all")
  end
end
