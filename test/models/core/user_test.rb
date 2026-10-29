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

  test "rejects passwords shorter than eight characters" do
    user = Core::User.new(phone: "+251911123457", password: "short", password_confirmation: "short")

    assert_not user.valid?
    assert_includes user.errors[:password], "is too short (minimum is 8 characters)"
  end

  test "rejects mismatched password confirmation" do
    user = Core::User.new(phone: "+251911123458", password: "password123", password_confirmation: "different")

    assert_not user.valid?
    assert_includes user.errors[:password_confirmation], "doesn't match Password"
  end

  test "rejects malformed phone numbers" do
    user = Core::User.new(phone: "12345", password: "password123", password_confirmation: "password123")

    assert_not user.valid?
    assert_includes user.errors[:phone], "The phone number is not a valid Ethiopian mobile number"
  end

  test "accepts canonical Ethiopian phone numbers" do
    user = Core::User.new(phone: "09 11 123 459", password: "password123", password_confirmation: "password123")

    assert_predicate user, :valid?
    assert_equal "+251911123459", user.phone
  end

  test "canonical phone spellings cannot create duplicate identities" do
    Core::User.create!(phone: "+251911123461", password: "password123", password_confirmation: "password123")
    duplicate = Core::User.new(phone: "0911123461", password: "password123", password_confirmation: "password123")

    assert_not duplicate.valid?
    assert_equal "+251911123461", duplicate.phone
    assert_includes duplicate.errors[:phone], "has already been taken"
  end

  test "permission helpers reflect active assigned permissions" do
    admin = core_users(:core_admin)

    assert admin.has_role?("CORE_ADMIN")
    assert admin.has_permission?("role.index")
    assert admin.has_all_permissions?("role.index", "permission.create")
    assert admin.has_any_permission?("permission.create", "user.index")
  end

  test "super admins bypass explicit permission checks" do
    user = core_users(:super_admin)

    assert user.super_admin?
    assert user.has_permission?("anything.at.all")
  end
end
