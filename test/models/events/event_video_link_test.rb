# frozen_string_literal: true

require "test_helper"

class Events::EventVideoLinkTest < ActiveSupport::TestCase
  def setup
    @event = events_events(:ready_listing)
    @user = core_users(:super_admin)
  end

  test "inheritance_column is disabled (no STI)" do
    assert Events::EventVideoLink.inheritance_column.blank?
  end

  test "url is required" do
    link = Events::EventVideoLink.new(event: @event, created_by: @user, provider: "youtube")
    refute link.valid?
    assert link.errors[:url].present?
  end

  test "rejects a non-YouTube url" do
    link = Events::EventVideoLink.new(
      event: @event, created_by: @user, provider: "youtube",
      url: "https://vimeo.com/123456"
    )
    refute link.valid?
    assert link.errors[:url].present?
  end

  test "accepts a youtube watch url" do
    link = Events::EventVideoLink.new(
      event: @event, created_by: @user, provider: "youtube",
      url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    )
    assert link.valid?, link.errors.full_messages.inspect
  end

  test "accepts a youtu.be short url" do
    link = Events::EventVideoLink.new(
      event: @event, created_by: @user, provider: "youtube",
      url: "https://youtu.be/dQw4w9WgXcQ"
    )
    assert link.valid?, link.errors.full_messages.inspect
  end

  test "created_by is required" do
    link = Events::EventVideoLink.new(
      event: @event, provider: "youtube",
      url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    )
    refute link.valid?
    assert link.errors[:created_by].present?
  end

  test "multiple links are allowed for the same event" do
    Events::EventVideoLink.create!(
      event: @event, created_by: @user, provider: "youtube",
      url: "https://www.youtube.com/watch?v=aaaaaaaaaaa"
    )
    second = Events::EventVideoLink.new(
      event: @event, created_by: @user, provider: "youtube",
      url: "https://www.youtube.com/watch?v=bbbbbbbbbbb"
    )
    assert second.valid?
  end

  test "position defaults to zero" do
    link = Events::EventVideoLink.create!(
      event: @event, created_by: @user, provider: "youtube",
      url: "https://www.youtube.com/watch?v=ccccccccccc"
    )
    assert_equal 0, link.position
  end
end
