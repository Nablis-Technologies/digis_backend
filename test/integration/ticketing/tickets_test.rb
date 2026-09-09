# frozen_string_literal: true

require "test_helper"

module Ticketing
  class TicketsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::PackageWorkflowTestHelpers

    setup { setup_package_workflow }

    test "owner wallet includes the resale policy needed for pre-submit UX" do
      @product.ticket_type.update!(
        resale_enabled: true,
        resale_price_cap_type: "percentage",
        resale_percentage_cap_bps: 7_500,
        resale_cutoff_seconds_before_start: 3_600,
        max_completed_resales: 4
      )

      get "/tickets", headers: headers_for(@owner), as: :json

      assert_response :success
      policy = response.parsed_body.fetch("data").sole.fetch("ticket_type")
      assert_equal true, policy.fetch("resale_enabled")
      assert_equal "percentage", policy.fetch("resale_price_cap_type")
      assert_equal 7_500, policy.fetch("resale_percentage_cap_bps")
      assert_equal 3_600, policy.fetch("resale_cutoff_seconds_before_start")
      assert_equal 4, policy.fetch("max_completed_resales")
    end

    test "owner wallet includes purchased non-ticket add-ons" do
      ticket = create_wallet_ticket_with_add_on

      get "/tickets", headers: headers_for(@owner), as: :json

      assert_response :success
      wallet_ticket = response.parsed_body.fetch("data").find { |entry| entry.fetch("id") == ticket.id }
      assert_equal [
        {
          "id" => ticket.order_item.order.order_items.find { |item| item.type_snapshot != "ticket" }.id,
          "name" => "Wallet add-on",
          "type" => "merchandise",
          "quantity" => 2,
          "unit_amount_minor" => 750
        }
      ], wallet_ticket.fetch("add_ons")
    end

    private

    def headers_for(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end

    def create_wallet_ticket_with_add_on
      order = Orders::Order.create!(
        event: @event, buyer_user: @owner, sales_channel: "online", status: "draft",
        charge_currency: "ETB", commercial_signature: "a" * 64,
        subtotal_minor: 4_500, discount_minor: 0, subsidy_minor: 0, fee_minor: 0,
        tax_minor: 0, adjustment_minor: 0, total_minor: 4_500,
        settlement_currency: "ETB", settlement_total_minor: 4_500,
        exchange_rate: 1, exchange_rate_source: "same_currency", expires_at: 1.day.from_now,
        idempotency_key_digest: SecureRandom.hex(32), creation_request_digest: SecureRandom.hex(32)
      )
      ticket_item = order.order_items.create!(
        event_product: @product, registration: nil, name_snapshot: @product.name, type_snapshot: "ticket",
        quantity: 1, admissions_per_unit_snapshot: @product.ticket_type.admissions_per_unit,
        base_currency: "ETB", base_unit_amount_minor: 3_000,
        charge_currency: "ETB", charge_unit_amount_minor: 3_000, exchange_rate: 1,
        discount_minor: 0, total_minor: 3_000, fulfillment_status: "fulfilled"
      )
      add_on = Catalog::EventProduct.create!(
        event: @event, name: "Wallet add-on", type: "merchandise", status: "active",
        inventory_mode: "unlimited", schedule_change_refund_policy: "full_or_partial"
      )
      order.order_items.create!(
        event_product: add_on, name_snapshot: add_on.name, type_snapshot: "merchandise",
        quantity: 2, base_currency: "ETB", base_unit_amount_minor: 750,
        charge_currency: "ETB", charge_unit_amount_minor: 750, exchange_rate: 1,
        discount_minor: 0, total_minor: 1_500, fulfillment_status: "fulfilled"
      )
      order.update_columns(status: "fulfilled", paid_at: Time.current)
      Ticketing::Packages::Issue.call(order_item: ticket_item, unit_number: 1).value
    end
  end
end
