# frozen_string_literal: true

require "test_helper"

module Catalog
  class CatalogAuthorizationTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @support = core_users(:support)
      @attendee = core_users(:attendee)
      @product = Catalog::EventProduct.create!(
        event: @event,
        name: "Policy product",
        type: "merchandise"
      )
      @inventory = Catalog::ProductInventory.create!(event_product: @product, capacity: 10)
      @price = Catalog::ProductPrice.create!(
        event_product: @product,
        type: "base",
        currency: "ETB",
        amount_minor: 1_000,
        active_from: 1.hour.ago
      )
    end

    test "platform admin can manage catalog" do
      assert Events::AuthorizationResolver.can_manage_catalog?(core_users(:super_admin), @event)
    end

    test "active primary organization admin can manage catalog" do
      Organizations::Membership.create!(
        organization: @event.organization,
        user: @support,
        role: "admin",
        status: "active"
      )

      assert Events::AuthorizationResolver.can_manage_catalog?(@support, @event)
      assert_includes Events::AuthorizationResolver.manageable_catalog_events(@support), @event
    end

    test "active event manager can manage catalog" do
      Events::EventStaffAssignment.create!(
        event: @event,
        user: @attendee,
        organization: @event.organization,
        role: "manager",
        status: "active"
      )

      assert Events::AuthorizationResolver.can_manage_catalog?(@attendee, @event)
      assert_includes Events::AuthorizationResolver.manageable_catalog_events(@attendee), @event
    end

    test "active co-organizer owner can manage catalog" do
      add_co_organizer(status: "active")

      assert Events::AuthorizationResolver.can_manage_catalog?(@support, @event)
      assert_includes Events::AuthorizationResolver.manageable_catalog_events(@support), @event
    end

    test "active manager assigned through a co-organizer can manage catalog" do
      add_co_organizer(status: "active")
      Events::EventStaffAssignment.create!(
        event: @event,
        user: @attendee,
        organization: organizations_organizations(:three),
        role: "manager",
        status: "active"
      )

      assert Events::AuthorizationResolver.can_manage_catalog?(@attendee, @event)
      assert_includes Events::AuthorizationResolver.manageable_catalog_events(@attendee), @event
    end

    test "revoked co-organizer cannot manage catalog" do
      add_co_organizer(status: "revoked")

      refute Events::AuthorizationResolver.can_manage_catalog?(@support, @event)
      refute_includes Events::AuthorizationResolver.manageable_catalog_events(@support), @event
    end

    test "staff membership scanner assignment and attendee cannot manage catalog" do
      Organizations::Membership.create!(
        organization: @event.organization,
        user: @attendee,
        role: "staff",
        status: "active"
      )
      Events::EventStaffAssignment.create!(
        event: @event,
        user: @attendee,
        organization: @event.organization,
        role: "scanner",
        status: "active"
      )

      refute Events::AuthorizationResolver.can_manage_catalog?(@attendee, @event)
      assert_empty Events::AuthorizationResolver.manageable_catalog_events(@attendee)
    end

    test "catalog policy scopes include managed events and exclude public unmanaged events" do
      add_co_organizer(status: "active")
      unmanaged_event = events_events(:draft_concert)
      unmanaged_event.update_columns(status: "published", visibility: "public")
      unmanaged_product = Catalog::EventProduct.create!(
        event: unmanaged_event,
        name: "Unmanaged public product",
        type: "merchandise"
      )
      unmanaged_inventory = Catalog::ProductInventory.create!(event_product: unmanaged_product, capacity: 10)
      unmanaged_price = Catalog::ProductPrice.create!(
        event_product: unmanaged_product,
        type: "base",
        currency: "ETB",
        amount_minor: 1_000,
        active_from: 1.hour.ago
      )

      assert_scope_only Catalog::EventProductPolicy::Scope, Catalog::EventProduct, @product, unmanaged_product
      assert_scope_only Catalog::ProductInventoryPolicy::Scope, Catalog::ProductInventory, @inventory, unmanaged_inventory
      assert_scope_only Catalog::ProductPricePolicy::Scope, Catalog::ProductPrice, @price, unmanaged_price
    end

    test "catalog policies deny raw reads and mutations to scanner" do
      Events::EventStaffAssignment.create!(
        event: @event,
        user: @attendee,
        organization: @event.organization,
        role: "scanner",
        status: "active"
      )

      refute Catalog::EventProductPolicy.new(@attendee, @product).update?
      refute Catalog::ProductInventoryPolicy.new(@attendee, @inventory).show?
      refute Catalog::ProductPricePolicy.new(@attendee, @price).show?
      refute Catalog::ProductPricePolicy.new(@attendee, @price).create?
    end

    private

    def add_co_organizer(status:)
      Events::EventOrganization.create!(
        event: @event,
        organization: organizations_organizations(:three),
        type: "co_organizer",
        role: "collaborator",
        status:
      )
    end

    def assert_scope_only(scope_class, model_class, managed_record, unmanaged_record)
      resolved = scope_class.new(@support, model_class).resolve
      assert_includes resolved, managed_record
      refute_includes resolved, unmanaged_record
    end
  end
end
