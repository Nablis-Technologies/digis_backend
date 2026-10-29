# frozen_string_literal: true

require "test_helper"

class Events::EventSettingTest < ActiveSupport::TestCase
  test "age restriction is optional and accepts the canonical restricted and unrestricted shapes" do
    setting = events_event_settings(:draft_concert_settings)
    assert_predicate setting, :valid?

    [
      { "has_restriction" => false },
      { "has_restriction" => true, "min_age" => 0 },
      { "has_restriction" => true, "max_age" => 120 },
      { "has_restriction" => true, "min_age" => 18, "max_age" => 21 }
    ].each do |age_restriction|
      setting.config = setting.config.merge("age_restriction" => age_restriction)
      assert_predicate setting, :valid?, age_restriction.inspect
    end
  end

  test "rejects malformed age restrictions and impossible ranges" do
    setting = events_event_settings(:draft_concert_settings)
    invalid_values = [
      {},
      { "has_restriction" => "true", "min_age" => 18 },
      { "has_restriction" => true },
      { "has_restriction" => true, "min_age" => "18" },
      { "has_restriction" => true, "min_age" => -1 },
      { "has_restriction" => true, "min_age" => 121 },
      { "has_restriction" => true, "max_age" => -1 },
      { "has_restriction" => true, "max_age" => 121 },
      { "has_restriction" => true, "min_age" => 22, "max_age" => 21 },
      { "has_restriction" => false, "min_age" => 18 }
    ]

    invalid_values.each do |age_restriction|
      setting.config = setting.config.merge("age_restriction" => age_restriction)
      assert_not setting.valid?, age_restriction.inspect
    end
  end

  test "age restriction assignment canonicalizes keys and omits null and unknown bounds" do
    setting = events_event_settings(:draft_concert_settings)
    public_guest_limit = setting.config.fetch("public_guest_limit")
    assert_respond_to setting, :age_restriction=

    setting.age_restriction = {
      has_restriction: true,
      min_age: nil,
      max_age: 30,
      ignored_internal_value: "do not persist"
    }

    assert_equal({ "has_restriction" => true, "max_age" => 30 }, setting.config.fetch("age_restriction"))
    assert_predicate setting, :valid?
    assert_equal public_guest_limit, setting.config.fetch("public_guest_limit")
  end

  test "safe age restriction returns canonical data only for valid stored values" do
    setting = events_event_settings(:draft_concert_settings)
    setting.config = setting.config.merge(
      "age_restriction" => {
        "has_restriction" => false,
        "ignored_internal_value" => "do not serialize"
      }
    )

    assert_equal({ "has_restriction" => false }, setting.safe_age_restriction)

    setting.config = setting.config.merge(
      "age_restriction" => { "has_restriction" => true, "min_age" => 121 }
    )
    assert_nil setting.safe_age_restriction
  end

  test "age assignment does not replace a malformed non-object config" do
    setting = events_event_settings(:draft_concert_settings)
    setting.config = []

    setting.age_restriction = { has_restriction: false }

    assert_equal [], setting.config
    assert_not setting.valid?
    assert setting.errors[:config].any?
  end
end
