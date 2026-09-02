# frozen_string_literal: true

require "test_helper"

module Catalog
  class EventProductsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
    end

    test "real JSON create normalizes inventory configuration and provisions inventory" do
      assert_difference -> { Catalog::EventProduct.count }, 1 do
        assert_difference -> { Catalog::ProductInventory.count }, 1 do
          post "/events/#{@event.id}/event_products",
               params: {
                 name: "Capacity-managed merchandise",
                 type: "merchandise",
                 inventory_configuration: {
                   mode: "event_wide",
                   capacity: 25
                 }
               },
               headers: owner_headers.merge("Idempotency-Key" => SecureRandom.uuid),
               as: :json
        end
      end

      assert_response :created
      product = Catalog::EventProduct.find(response.parsed_body.dig("data", "id"))
      assert_equal "event_wide", product.inventory_mode
      assert_equal 25, product.inventories.sole.capacity
    end

    test "real JSON inventory update normalizes configuration and provisions inventory" do
      product = create_product(name: "Configurable merchandise")

      patch "/events/#{@event.id}/event_products/#{product.id}/update_inventory_configuration",
           params: {
             inventory_configuration: {
               mode: "event_wide",
               capacity: 40
             }
           },
           headers: owner_headers,
           as: :json

      assert_response :ok
      assert_equal "event_wide", product.reload.inventory_mode
      assert_equal 40, product.inventories.sole.capacity
    end

    test "create response includes the ticket type allowed by organizer visibility" do
      post "/events/#{@event.id}/event_products",
           params: {
             name: "Organizer ticket",
             type: "ticket",
             ticket_type_attributes: {
               approval_mode: "automatic",
               audience: "public",
               date_selection: "fixed",
               admissions_per_unit: 1
             },
             inventory_configuration: { mode: "unlimited" }
           },
           headers: owner_headers.merge("Idempotency-Key" => SecureRandom.uuid),
           as: :json

      assert_response :created
      assert_equal "automatic", response.parsed_body.dig("data", "ticket_type", "approval_mode")
    end

    test "organizer product responses include ticket type pricing accesses and inventory" do
      date = @event.event_dates.create!(
        name: "Opening night",
        starts_at: 2.days.from_now,
        ends_at: 2.days.from_now + 3.hours,
        status: "scheduled",
        venue: events_venues(:grand_palace),
        venue_capacity: 5000
      )
      product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Organizer general admission", type: "ticket" },
        ticket_type_attributes: {
          approval_mode: "automatic",
          audience: "public",
          date_selection: "fixed",
          admissions_per_unit: 1,
          entry_validation_mode: "qr"
        },
        price_attributes: { type: "base", currency: "ETB", amount_minor: 500, active_from: 1.hour.ago },
        inventory_configuration: { mode: "event_wide", capacity: 100 },
        idempotency_key: SecureRandom.uuid
      ).value
      product.product_accesses.create!(event_date: date, type: "venue")

      get "/events/#{@event.id}/event_products/#{product.id}", headers: owner_headers, as: :json

      assert_response :ok
      payload = response.parsed_body.fetch("data")
      assert_equal product.ticket_type.id, payload.dig("ticket_type", "id")
      assert_equal 1, payload.dig("ticket_type", "admissions_per_unit")
      assert_equal 500, payload.dig("pricing", "options", 0, "amount_minor")
      assert_equal "ETB", payload.dig("pricing", "options", 0, "currency")
      assert_equal date.id, payload.dig("product_accesses", 0, "event_date", "id")
      assert_equal "Grand Palace", payload.dig("product_accesses", 0, "event_date", "venue", "name")
      assert_equal 100, payload.dig("inventory", "pools", 0, "capacity")
      assert_equal 100, payload.dig("inventory", "pools", 0, "available_count")
    end

    test "active co-organizer owner can create an event product" do
      Events::EventOrganization.create!(
        event: @event,
        organization: organizations_organizations(:three),
        type: "co_organizer",
        role: "collaborator",
        status: "active"
      )

      post "/events/#{@event.id}/event_products",
           params: {
             name: "Partner merchandise",
             type: "merchandise",
             inventory_configuration: { mode: "unlimited" }
           },
           headers: headers_for(:support).merge("Idempotency-Key" => SecureRandom.uuid),
           as: :json

      assert_response :created
    end

    test "scanner cannot create an event product" do
      Events::EventStaffAssignment.create!(
        event: @event,
        user: core_users(:attendee),
        organization: @event.organization,
        role: "scanner",
        status: "active"
      )

      assert_no_difference -> { Catalog::EventProduct.count } do
        post "/events/#{@event.id}/event_products",
             params: {
               name: "Scanner product",
               type: "merchandise",
               inventory_configuration: { mode: "unlimited" }
             },
             headers: user_headers.merge("Idempotency-Key" => SecureRandom.uuid),
             as: :json
      end

      assert_response :not_found
    end

    test "public event reader cannot list raw inventory or price definitions" do
      @event.update_columns(status: "published", visibility: "public")
      product = create_product(name: "Internal catalog definition")
      Catalog::ProductInventory.create!(event_product: product, capacity: 100)
      Catalog::ProductPrice.create!(
        event_product: product,
        type: "base",
        currency: "ETB",
        amount_minor: 10_000,
        active_from: 1.hour.ago
      )

      get "/catalog/product_inventories", headers: user_headers, as: :json
      assert_response :forbidden

      get "/catalog/product_prices", headers: user_headers, as: :json
      assert_response :forbidden
    end

    private

    def create_product(name:)
      Catalog::EventProduct.create!(
        event: @event,
        name:,
        type: "merchandise",
        inventory_mode: "unlimited"
      )
    end

    def headers_for(user_fixture)
      token = issue_token(user_fixture)
      { "Authorization" => "Bearer #{token}" }
    end
  end
end
