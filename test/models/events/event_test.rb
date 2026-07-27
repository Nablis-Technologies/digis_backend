# frozen_string_literal: true

require "test_helper"

class Events::EventTest < ActiveSupport::TestCase
  test "has a uuid primary key and references the owning organization" do
    event = events_events(:draft_concert)
    assert event.id.is_a?(String)
    assert_equal organizations_organizations(:one).id, event.organization_id
  end

  test "lowercase slug is unique through a functional index" do
    duplicate = Events::Event.new(
      organization: organizations_organizations(:one),
      created_by: core_users(:super_admin),
      title: "Draft Concert",
      slug: "DRAFT-CONCERT",
      status: "draft",
      visibility: "private",
      timezone: "Africa/Addis_Ababa",
      currency: "ETB"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:slug], I18n.t("errors.messages.slug_taken")
  end

  test "one settings row per event" do
    assert_raises(ActiveRecord::RecordNotUnique) do
      Events::EventSetting.create!(
        event: events_events(:draft_concert),
        config: {}
      )
    end
  end

  test "one category pair per event" do
    assert_raises(ActiveRecord::RecordInvalid) do
      Events::EventCategory.create!(
        event: events_events(:draft_concert),
        category: events_categories(:music)
      )
    end
  end

  test "status and timestamps are coupled" do
    event = Events::Event.create!(
      organization: organizations_organizations(:one),
      created_by: core_users(:super_admin),
      title: "Coupled Event",
      slug: "coupled-event",
      status: "published",
      visibility: "public",
      timezone: "Africa/Addis_Ababa",
      currency: "ETB"
    )
    assert_equal "published", event.status
    assert event.published_at.present?
  end

  test "version is non-negative" do
    event = events_events(:draft_concert)
    event.version = -1
    assert_not event.valid?
    assert_includes event.errors[:version], I18n.t("errors.messages.version_non_negative")
  end

  test "rejects an unsupported currency" do
    event = Events::Event.new(
      organization: organizations_organizations(:one),
      created_by: core_users(:super_admin),
      title: "Bad Currency",
      slug: "bad-currency",
      status: "draft",
      visibility: "private",
      timezone: "Africa/Addis_Ababa",
      currency: "US"
    )
    assert_not event.valid?
    assert_includes event.errors[:currency], I18n.t("errors.messages.invalid_currency")
  end

  test "rejects an unsupported timezone" do
    event = Events::Event.new(
      organization: organizations_organizations(:one),
      created_by: core_users(:super_admin),
      title: "Bad TZ",
      slug: "bad-tz",
      status: "draft",
      visibility: "private",
      timezone: "Not/AZone",
      currency: "ETB"
    )
    assert_not event.valid?
    assert_includes event.errors[:timezone], I18n.t("errors.messages.invalid_timezone")
  end

  test "associations resolve categories and settings" do
    event = events_events(:draft_concert)
    assert_includes event.categories, events_categories(:music)
    assert event.event_setting.present?
  end
end
