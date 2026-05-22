require "test_helper"

class EventsCategoryTest < ActiveSupport::TestCase
  test "requires name" do
    category = Events::Category.new(name: nil)

    assert_not category.valid?
    assert_includes category.errors[:name], "can't be blank"
  end

  test "requires unique name (case-insensitive)" do
    existing = events_categories(:music)
    category = Events::Category.new(name: "MUSIC")

    assert_not category.valid?
    assert_includes category.errors[:name], "has already been taken"
  end

  test "generates slug from name automatically" do
    category = Events::Category.create!(name: "Art Exhibition", metadata: {})

    assert_equal "art-exhibition", category.slug
  end

  test "handles duplicate slugs with counter" do
    Events::Category.create!(name: "Test Event", metadata: {})
    category = Events::Category.create!(name: "Test-Event", metadata: {})

    assert_equal "test-event-1", category.slug
  end

  test "metadata defaults to empty hash" do
    category = Events::Category.new(name: "Test")
    category.valid?

    assert_equal({}, category.metadata)
  end

  test "active scope returns only active categories" do
    active_count = Events::Category.active.count
    total_count = Events::Category.count

    assert active_count < total_count
    assert_equal active_count, Events::Category.where(active: true).count
  end

  test "alphabetical scope orders by name" do
    categories = Events::Category.alphabetical.pluck(:name)

    assert_equal categories, categories.sort
  end

  test "ransackable_attributes returns safe attributes" do
    expected = %w[id name description slug active created_at updated_at]

    assert_equal expected, Events::Category.ransackable_attributes
  end

  test "ransackable_associations returns empty array" do
    assert_equal [], Events::Category.ransackable_associations
  end
end
