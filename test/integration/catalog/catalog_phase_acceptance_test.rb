# frozen_string_literal: true

require "test_helper"

module Catalog
  class CatalogPhaseAcceptanceTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @event.update_columns(status: "published", visibility: "public")
      result = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: {
          name: "Group hybrid ticket",
          type: "ticket",
          schedule_change_refund_policy: "full_only"
        },
        ticket_type_attributes: {
          approval_mode: "automatic",
          audience: "code_or_invitation",
          date_selection: "fixed",
          admissions_per_unit: 3
        },
        price_attributes: {
          type: "base",
          currency: "ETB",
          amount_minor: 10_000,
          active_from: 1.hour.ago
        },
        inventory_configuration: { mode: "event_wide", capacity: 100 },
        idempotency_key: "catalog-phase-acceptance-product"
      )
      assert result.success?, result.error&.message
      @product = Catalog::Products::Activate.call(product: result.value, actor: core_users(:super_admin)).value
      assert Core::OutboxEvent.exists?(
        event_type: "catalog.product.activated", aggregate_id: @product.id
      )
      @ticket_type = @product.ticket_type
      @raw_code = "PHASE-GROUP"
      @access_code = Ticketing::AccessCode.create!(
        ticket_type: @ticket_type,
        code_digest: Ticketing::AccessCode.code_digest_for(event_id: @event.id, code: @raw_code),
        max_quantity_per_use: 3,
        max_uses: 10
      )
    end

      test "catalog phase exposes ticket policy, audience authorization, and public product boundaries" do
      get "/events/#{@event.id}/event_products/#{@product.id}/ticket_type", headers: owner_headers, as: :json
      assert_response :success
      assert_equal 3, response.parsed_body.dig("data", "admissions_per_unit")

      get "/events/#{@event.id}/event_products/#{@product.id}/ticket_type", headers: user_headers, as: :json
      assert_response :not_found

      post "/ticketing/audience_authorizations",
           params: { ticket_type_id: @ticket_type.id, access_code: @raw_code },
           as: :json
      assert_response :success
      assert_equal "access_code", response.parsed_body.dig("data", "reason")

      post "/events/#{@event.id}/event_products/#{@product.id}/ticket_type/access_codes",
           params: { code: "NEW-PHASE-CODE", max_uses: 5, max_quantity_per_use: 1 },
           headers: owner_headers.merge("Idempotency-Key" => "catalog-phase-code-create"),
           as: :json
      assert_response :created
      assert_equal "NEW-PHASE-CODE", response.parsed_body.dig("data", "code")

      post "/events/#{@event.id}/event_products/#{@product.id}/ticket_type/invitations",
           params: {
             email: "phase-guest@example.com",
             name: "Phase guest",
             allowed_quantity: 1,
             expires_at: 1.day.from_now.iso8601
           },
           headers: owner_headers.merge("Idempotency-Key" => "catalog-phase-invitation-create"),
           as: :json
      assert_response :created
      invitation_data = response.parsed_body.fetch("data")
      assert invitation_data["token"].present?
      refute invitation_data.key?("contact_digest")
      refute invitation_data.key?("email")

      invitation = Ticketing::Invitation.find(invitation_data.fetch("id"))
      assert Core::OutboxEvent.exists?(
        event_type: "ticketing.invitation.created", aggregate_id: invitation.id
      )
      invitation.update!(expires_at: 1.minute.ago)
      Ticketing::ExpireInvitationsJob.perform_now
      assert_equal "expired", invitation.reload.status

      get "/public/events/#{@event.slug}/products", as: :json
      assert_response :success
      public_product = response.parsed_body.fetch("data").find { |item| item["id"] == @product.id }
      assert public_product
      refute public_product.key?("held_count")
      refute public_product.key?("sold_count")

      public_ticket_type = public_product.fetch("ticket_type")
      assert_equal 3, public_ticket_type.fetch("admissions_per_unit")
      refute public_ticket_type.key?("resale_enabled")
      refute public_ticket_type.key?("delegation_enabled")
        refute public_ticket_type.key?("max_packages_per_user")
      end

      test "access-code creation requires a key and replays the original secret" do
        params = { code: "HTTP-REPLAY-CODE", max_uses: 5, max_quantity_per_use: 1 }
        post "/events/#{@event.id}/event_products/#{@product.id}/ticket_type/access_codes",
             params:, headers: owner_headers, as: :json

        assert_response :bad_request
        assert_equal "missing_idempotency_key", response.parsed_body["code"]

        headers = owner_headers.merge("Idempotency-Key" => "http-access-code-replay")
        assert_difference -> { Ticketing::AccessCode.count }, 1 do
          post "/events/#{@event.id}/event_products/#{@product.id}/ticket_type/access_codes",
               params:, headers:, as: :json
          assert_response :created
          @first_access_code_response = response.parsed_body

          post "/events/#{@event.id}/event_products/#{@product.id}/ticket_type/access_codes",
               params:, headers:, as: :json
          assert_response :created
        end

        assert_equal @first_access_code_response, response.parsed_body
      end

      test "invitation creation requires a key and replays the original secret" do
        params = { email: "http-replay@example.com", name: "HTTP replay guest", allowed_quantity: 1 }
        post "/events/#{@event.id}/event_products/#{@product.id}/ticket_type/invitations",
             params:, headers: owner_headers, as: :json

        assert_response :bad_request
        assert_equal "missing_idempotency_key", response.parsed_body["code"]

        headers = owner_headers.merge("Idempotency-Key" => "http-invitation-replay")
        assert_difference -> { Ticketing::Invitation.count }, 1 do
          post "/events/#{@event.id}/event_products/#{@product.id}/ticket_type/invitations",
               params:, headers:, as: :json
          assert_response :created
          @first_invitation_response = response.parsed_body

          post "/events/#{@event.id}/event_products/#{@product.id}/ticket_type/invitations",
               params:, headers:, as: :json
          assert_response :created
        end

        assert_equal @first_invitation_response, response.parsed_body
      end

    test "catalog and ticketing outbox handlers and recurring expiry are registered" do
      handlers = Rails.application.config.x.outbox_handlers

      assert handlers.key?("catalog.product.activated")
      assert handlers.key?("catalog.product.retired")
      assert handlers.key?("ticketing.invitation.created")

      recurring = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
      assert recurring.fetch("production").key?("expire_invitations")
    end

    test "accepts a three-day group ticket with hybrid access, allocations, promotion, and audience proofs" do
      dates = 3.times.map do |index|
        Events::EventDate.create!(
          event: @event,
          name: "Hybrid day #{index + 1}",
          starts_at: (index + 1).days.from_now,
          ends_at: (index + 1).days.from_now + 4.hours,
          venue_capacity: 100
        )
      end
      zones = dates.map do |date|
        Events::AccessZone.create!(
          event: @event,
          event_date: date,
          code: "HYBRID-#{date.id}",
          name: "Hybrid gate",
          type: "venue",
          sort_order: 0
        )
      end

      created = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Hybrid group pass", type: "ticket" },
        ticket_type_attributes: {
          approval_mode: "automatic",
          audience: "code_or_invitation",
          date_selection: "fixed",
          admissions_per_unit: 3
        },
        price_attributes: {
          type: "base", currency: "ETB", amount_minor: 10_000, active_from: 1.hour.ago
        },
        inventory_configuration: { mode: "event_wide", capacity: 100 },
        idempotency_key: "catalog-hybrid-acceptance"
      )
      assert created.success?, created.error&.message
      product = created.value
      Catalog::ProductPrice.create!(
        event_product: product,
        type: "override",
        currency: "USD",
        amount_minor: 2_500,
        active_from: 1.hour.ago
      )

      accesses = dates.flat_map do |date|
        [
          { event_date_id: date.id, type: "venue", usage_limit: 1 },
          { event_date_id: date.id, type: "stream", required_access_protection: "public" }
        ]
      end
      access_result = Catalog::Accesses::Replace.call(product:, accesses:)
      assert access_result.success?, access_result.error&.message
      product.product_accesses.where(type: "venue").find_each do |access|
        zone = zones.fetch(dates.index { |date| date.id == access.event_date_id })
        access.product_access_zones.create!(access_zone: zone)
      end

      allocation_result = Catalog::DateAllocations::Replace.call(
        product:,
        allocations: dates.zip([ 5_000, 2_500, 2_500 ]).map do |date, basis_points|
          { event_date_id: date.id, allocation_basis_points: basis_points }
        end
      )
      assert allocation_result.success?, allocation_result.error&.message

      activated = Catalog::Products::Activate.call(product:, actor: core_users(:super_admin))
      assert activated.success?, activated.error&.message
      assert_equal 3, product.reload.ticket_type.admissions_per_unit
      assert_equal 2_500, Catalog::Pricing::Quote.call(
        product:, charge_currency: "USD"
      ).value.amount_minor
      assert_equal [ 5_000, 2_500, 2_500 ], product.product_date_allocations.order(:event_date_id)
        .pluck(:allocation_basis_points)

      promotion = Catalog::Promotions::Create.call(
        event: @event,
        actor: core_users(:super_admin),
        attributes: {
          name: "Hybrid launch discount",
          type: "percentage",
          percentage_basis_points: 1_000,
          currency: "ETB",
          per_user_limit: 1
        },
        product_ids: [ product.id ],
        idempotency_key: "catalog-hybrid-promotion"
      ).value
      assert Catalog::Promotions::PublishVersion.call(
        promotion:, actor: core_users(:super_admin), idempotency_key: "catalog-hybrid-publish"
      ).success?
      code = Catalog::Promotions::CreateCode.call(
        promotion:,
        actor: core_users(:super_admin),
        attributes: { code: "HYBRID10" },
        idempotency_key: "catalog-hybrid-code"
      ).value
      promotion_quote = Catalog::Promotions::Quote.call(
        promotion:,
        code: code.plaintext,
        eligible_product_ids: [ product.id ],
        eligible_subtotal_minor: 25_000,
        charge_currency: "ETB"
      )
      assert promotion_quote.success?, promotion_quote.error&.message
      assert_equal 2_500, promotion_quote.value.discount_minor

      access_code = Ticketing::AccessCodes::Create.call(
        ticket_type: product.ticket_type,
        actor: core_users(:super_admin),
        attributes: { code: "HYBRID-CODE", max_uses: 5 },
        idempotency_key: "catalog-hybrid-access-code"
      ).value
      assert Ticketing::Audience::Authorize.call(
        ticket_type: product.ticket_type, access_code: access_code.plaintext
      ).success?

      invitation = Ticketing::Invitations::Create.call(
        ticket_type: product.ticket_type,
        actor: core_users(:super_admin),
        attributes: { email: "hybrid-guest@example.com" },
        idempotency_key: "catalog-hybrid-invitation"
      ).value
      assert Ticketing::Audience::Authorize.call(
        ticket_type: product.ticket_type, invitation: invitation.token
      ).success?
    end
  end
end
