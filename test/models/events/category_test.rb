require "test_helper"

class Events::CategoryTest < ActiveSupport::TestCase
  include Core::SlugableTest
  test_slugable

  should validate_presence_of(:name)
  should validate_uniqueness_of(:name).case_insensitive

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
