# frozen_string_literal: true

require "test_helper"

module Catalog
  class EventProductTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
    end

    test "type allowlist rejects unknown types" do
      product = Catalog::EventProduct.new(event: @event, name: "X", type: "bogus")
      assert product.invalid?
      assert_includes product.errors[:type], "is not included in the list"
    end

    test "inheritance_column is disabled so type is a plain attribute" do
      assert Catalog::EventProduct.inheritance_column.blank?
      product = Catalog::EventProduct.new(event: @event, name: "X", type: "ticket")
      assert_equal "ticket", product.type
    end

    test "min_per_order must be at least 1" do
      product = Catalog::EventProduct.new(event: @event, name: "X", type: "ticket", min_per_order: 0)
      assert product.invalid?
      assert_includes product.errors[:min_per_order], "must be greater than or equal to 1"
    end

    test "max_per_order must be greater than or equal to min_per_order" do
      product = Catalog::EventProduct.new(
        event: @event, name: "X", type: "ticket", min_per_order: 3, max_per_order: 2
      )
      assert product.invalid?
      assert_includes product.errors[:max_per_order], "must be greater than or equal to min_per_order"
    end

    test "sales_end_at must be after sales_start_at" do
      product = Catalog::EventProduct.new(
        event: @event, name: "X", type: "ticket",
        sales_start_at: 2.days.from_now, sales_end_at: 1.day.from_now
      )
      assert product.invalid?
      assert_includes product.errors[:sales_end_at], "must be after sales_start_at"
    end

    test "ticket products require a ticket type" do
      product = Catalog::EventProduct.new(event: @event, name: "VIP", type: "ticket")
      assert product.invalid?
      assert_includes product.errors[:ticket_type], "must be present for ticket products"
    end

    test "non-ticket products must not have a ticket type" do
      ticket = create_ticket_product
      merch = Catalog::EventProduct.new(event: @event, name: "Shirt", type: "merchandise")
      merch.ticket_type = ticket.ticket_type
      assert merch.invalid?
      assert_includes merch.errors[:ticket_type], "must not be present for non-ticket products"
    end

    test "a ticket product with a ticket type is valid" do
      product = create_ticket_product
      assert product.valid?
      assert_equal "ticket", product.type
      assert product.ticket_type.persisted?
    end

    private

    def create_ticket_product
      Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "VIP", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
    end
  end
end
