# frozen_string_literal: true

require "test_helper"

# Exercises the deferred DB constraint trigger on catalog_product_date_allocations.
# Requires real commits, so it runs without transactional fixtures and cleans up
# after itself.
class Catalog::ProductDateAllocationTriggerTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  def setup
    @event = events_events(:ready_listing)
  end

  def teardown
    Catalog::ProductDateAllocation.where(event_product: @product).delete_all if @product
    @product&.destroy
    @date&.destroy
    @product = nil
    @date = nil
  end

  test "deferred constraint trigger rejects a committed sum below 10000 basis points" do
    @product = Catalog::EventProduct.create!(
      event: @event, name: "Trigger Test Pass", type: "merchandise",
      status: "draft", inventory_mode: "unlimited"
    )
    @date = Events::EventDate.create!(
      event: @event, starts_at: 1.day.from_now, ends_at: 1.day.from_now + 4.hours
    )

    assert_raises(ActiveRecord::CheckViolation) do
      Catalog::ProductDateAllocation.create!(
        event_product: @product,
        event_date: @date,
        allocation_basis_points: 5_000
      )
    end
  end

  test "deferred constraint trigger accepts a committed sum of exactly 10000 basis points" do
    @product = Catalog::EventProduct.create!(
      event: @event, name: "Trigger Pass OK", type: "merchandise",
      status: "draft", inventory_mode: "unlimited"
    )
    date_two = Events::EventDate.create!(
      event: @event, starts_at: 2.days.from_now, ends_at: 2.days.from_now + 4.hours
    )
    @date = Events::EventDate.create!(
      event: @event, starts_at: 1.day.from_now, ends_at: 1.day.from_now + 4.hours
    )
    @date_extra = date_two

    Catalog::ProductDateAllocation.transaction do
      Catalog::ProductDateAllocation.create!(
        event_product: @product, event_date: @date, allocation_basis_points: 6_000
      )
      Catalog::ProductDateAllocation.create!(
        event_product: @product, event_date: date_two, allocation_basis_points: 4_000
      )
    end

    assert_equal 10_000,
                 Catalog::ProductDateAllocation.where(event_product: @product).sum(:allocation_basis_points)
  ensure
    Catalog::ProductDateAllocation.where(event_product: @product).delete_all if @product
    @date_extra&.destroy
    @product&.destroy
    @date&.destroy
  end
end
