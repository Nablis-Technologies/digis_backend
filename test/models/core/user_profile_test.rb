require "test_helper"

class CoreUserProfileTest < ActiveSupport::TestCase
  test "users have an optional one-to-one profile association" do
    reflection = Core::User.reflect_on_association(:profile)

    assert_not_nil reflection
    assert_equal :has_one, reflection.macro
    assert_equal "Core::UserProfile", reflection.class_name
  end

  test "rejects a second profile for the same user" do
    user = core_users(:attendee)
    Core::UserProfile.create!(user: user, first_name: "Aster", last_name: "Bekele")
    duplicate = Core::UserProfile.new(user: user, first_name: "Mimi", last_name: "Abebe")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:user_id], "has already been taken"
  end

  test "normalizes and trims Unicode names to NFC" do
    profile = Core::UserProfile.new(
      user: core_users(:attendee),
      first_name: "  A\u0308ster ",
      last_name: "አስቴር  "
    )

    profile.valid?

    assert_equal "Äster", profile.first_name
    assert_equal "አስቴር", profile.last_name
  end

  test "requires both names and rejects control characters" do
    profile = Core::UserProfile.new(user: core_users(:attendee), first_name: nil, last_name: "A\u0000B")

    assert_not profile.valid?
    assert_includes profile.errors.attribute_names, :first_name
    assert_includes profile.errors.attribute_names, :last_name
  end

  test "limits each name to 100 characters" do
    profile = Core::UserProfile.new(
      user: core_users(:attendee),
      first_name: "A" * 101,
      last_name: "Bekele"
    )

    assert_not profile.valid?
    assert_includes profile.errors[:first_name], "is too long (maximum is 100 characters)"
  end

  test "full name joins the normalized given and additional names" do
    profile = Core::UserProfile.new(
      user: core_users(:attendee),
      first_name: " Aster ",
      last_name: "Bekele"
    )

    assert_respond_to profile, :full_name
    assert_equal "Aster Bekele", profile.full_name
  end
end
