# frozen_string_literal: true

require "test_helper"

class Events::ReplaceCategoriesTest < ActiveSupport::TestCase
  test "replaces at most three categories atomically" do
    event = events_events(:draft_concert)
    ids = Events::Category.where(slug: %w[music festival nightlife education]).pluck(:id)

    result = Events::ReplaceCategories.call(
      event:,
      category_ids: ids,
      actor: core_users(:super_admin)
    )

    assert result.failure?
    assert_equal "too_many_categories", result.error.code
    assert_equal events_categories(:music).id,
                 events_event_categories(:draft_music).reload.category_id
  end

  test "replaces categories within the limit" do
    event = events_events(:draft_concert)
    ids = Events::Category.where(slug: %w[music festival nightlife]).pluck(:id)

    result = Events::ReplaceCategories.call(
      event:,
      category_ids: ids,
      actor: core_users(:super_admin)
    )

    assert result.success?, result.error&.inspect
    assert_equal 3, event.event_categories.reload.count
    assert_equal ids.sort, event.categories.reload.pluck(:id).sort
  end

  test "two concurrent replacements cannot leave more than three rows" do
    event = events_events(:draft_concert)
    first_ids = Events::Category.where(slug: %w[music festival nightlife]).pluck(:id)
    second_ids = Events::Category.where(slug: %w[music festival education]).pluck(:id)

    Events::ReplaceCategories.call(
      event:,
      category_ids: first_ids,
      actor: core_users(:super_admin)
    )

    result = Events::ReplaceCategories.call(
      event:,
      category_ids: second_ids,
      actor: core_users(:super_admin)
    )

    assert result.success?
    assert_operator event.event_categories.reload.count, :<=, 3
  end
end
