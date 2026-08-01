# frozen_string_literal: true

require "test_helper"

module Catalog
  class ProductAccessTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @date = Events::EventDate.create!(event: @event, starts_at: 1.day.from_now,
                                        ends_at: 1.day.from_now + 4.hours)
      @product = Catalog::EventProduct.create!(event: @event, name: "Test Pass",
                                                type: "merchandise", status: "draft",
                                                inventory_mode: "unlimited")
    end

    test "venue access is valid with default usage limit" do
      access = Catalog::ProductAccess.new(
        event_product: @product,
        event_date: @date,
        type: "venue"
      )
      assert access.valid?, access.errors.full_messages.join(", ")
    end

    test "stream access requires required_access_protection" do
      access = Catalog::ProductAccess.new(
        event_product: @product,
        event_date: @date,
        type: "stream"
      )
      refute access.valid?
      assert_equal 1, access.errors[:required_access_protection].size
    end

    test "stream access is valid with signed protection" do
      access = Catalog::ProductAccess.new(
        event_product: @product,
        event_date: @date,
        type: "stream",
        required_access_protection: "signed"
      )
      assert access.valid?, access.errors.full_messages.join(", ")
    end

    test "venue access rejects required_access_protection" do
      access = Catalog::ProductAccess.new(
        event_product: @product,
        event_date: @date,
        type: "venue",
        required_access_protection: "signed"
      )
      refute access.valid?
      assert_equal 1, access.errors[:required_access_protection].size
    end

    test "parking access is valid" do
      access = Catalog::ProductAccess.new(
        event_product: @product,
        event_date: @date,
        type: "parking"
      )
      assert access.valid?, access.errors.full_messages.join(", ")
    end

    test "enforces unique product-date-type constraint" do
      Catalog::ProductAccess.create!(
        event_product: @product,
        event_date: @date,
        type: "venue"
      )
      duplicate = Catalog::ProductAccess.new(
        event_product: @product,
        event_date: @date,
        type: "venue"
      )
      refute duplicate.valid?
    end

    test "usage limit above zero is valid" do
      access = Catalog::ProductAccess.new(
        event_product: @product,
        event_date: @date,
        type: "venue",
        usage_limit: 3
      )
      assert access.valid?, access.errors.full_messages.join(", ")
    end

    test "usage limit nil is valid (unlimited)" do
      access = Catalog::ProductAccess.new(
        event_product: @product,
        event_date: @date,
        type: "venue",
        usage_limit: nil
      )
      assert access.valid?, access.errors.full_messages.join(", ")
    end

    test "usage limit zero is invalid" do
      access = Catalog::ProductAccess.new(
        event_product: @product,
        event_date: @date,
        type: "venue",
        usage_limit: 0
      )
      refute access.valid?
    end

    test "event date must belong to same event" do
      other_event = events_events(:draft_concert)
      other_date = Events::EventDate.create!(
        event: other_event,
        starts_at: 1.day.from_now,
        ends_at: 1.day.from_now + 4.hours
      )
      access = Catalog::ProductAccess.new(
        event_product: @product,
        event_date: other_date,
        type: "venue"
      )
      refute access.valid?
    end

    test "STI is disabled on type column" do
      access = Catalog::ProductAccess.create!(
        event_product: @product,
        event_date: @date,
        type: "venue"
      )
      access.reload
      assert_equal "venue", access.type
      assert_equal "Catalog::ProductAccess", access.class.name
    end
  end
end
