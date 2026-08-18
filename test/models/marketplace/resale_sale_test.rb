# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ResaleSaleTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers
    include Commercial::FeeDefinitionTestHelpers
    include Finance::LedgerTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1, delegation_enabled: false)
      @buyer = core_users(:core_admin)
      @schedule = create_schedule(code: "resale_sale_#{SecureRandom.hex(4)}")
      @version = create_version(@schedule)
      @component = create_component(
        @version,
        component_type: "resale_platform_fee",
        calculation_type: "fixed",
        charged_to: "buyer",
        funded_by: "buyer",
        sale_context: "resale",
        basis_type: nil,
        rate_bps: nil
      )
      @buyer_order = create_buyer_order
      @buyer_registration = create_buyer_registration
      @listing = create_reserved_listing
      @buyer_order_item = create_buyer_order_item
      @buyer_order.update_columns(status: "fulfilled", paid_at: Time.current)
      @accepted_payment = create_accepted_payment(order: @buyer_order)
    end

    test "rejects a sale where seller and buyer are the same user" do
      sale = build_sale(buyer_user: @owner)

      assert_not sale.valid?
      assert_includes sale.errors.attribute_names, :buyer_user
    end

    test "rejects a sale whose gross amount does not reconcile" do
      sale = build_sale(gross_amount_minor: 7_501)

      assert_not sale.valid?
      assert_includes sale.errors.attribute_names, :gross_amount_minor
    end

    test "database permits one sale for a listing only" do
      create_sale!

      assert_raises(ActiveRecord::RecordNotUnique) do
        create_sale!(idempotency_key: "sale-#{SecureRandom.hex(8)}")
      end
    end

    test "allows cancellation status transitions without changing the sale snapshot" do
      sale = create_sale!

      sale.update!(status: "partially_cancelled")

      assert_equal "partially_cancelled", sale.reload.status
    end

    test "database rejects mutation of the completed sale snapshot" do
      sale = create_sale!

      assert_raises(ActiveRecord::StatementInvalid) do
        sale.update_columns(gross_amount_minor: 7_000)
      end
    end

    test "database rejects a seller-ledger row outside the sale scope" do
      sale = create_sale!

      assert_raises(ActiveRecord::StatementInvalid) do
        SellerLedgerEntry.insert_all!([
          {
          id: SecureRandom.uuid,
          seller_user_id: @buyer.id,
          event_id: @event.id,
          resale_sale_id: sale.id,
          type: "resale_proceeds",
          amount_minor: 7_500,
          currency: "ETB",
          available_at: 1.day.from_now,
          idempotency_key: "seller-ledger-#{SecureRandom.hex(8)}",
          created_at: Time.current
          }
        ])
      end
    end

    test "rejects mismatched payment and buyer order" do
      other_order = create_buyer_order(sales_channel: "online")
      other_order.update_columns(status: "fulfilled", paid_at: Time.current)
      other_payment = create_accepted_payment(order: other_order)
      sale = build_sale(accepted_payment: other_payment)

      assert_not sale.valid?
      assert_includes sale.errors.attribute_names, :accepted_payment
    end

    test "database rejects a registration from another buyer" do
      assert_raises(ActiveRecord::StatementInvalid) do
        create_sale!(
          buyer_registration: @registration,
          idempotency_key: "sale-#{SecureRandom.hex(8)}"
        )
      end
    end

    private

    def create_buyer_order(sales_channel: "resale")
      Orders::Order.create!(
        event: @event,
        buyer_user: @buyer,
        sales_channel:,
        status: "draft",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 7_500,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 7_500,
        settlement_currency: "ETB",
        settlement_total_minor: 7_500,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
    end

    def create_buyer_registration
      Ticketing::Registration.create!(
        event: @event,
        ticket_type: @product.ticket_type,
        user: @buyer,
        created_by: @buyer,
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "confirmed",
        submitted_at: Time.current,
        confirmed_at: Time.current,
        idempotency_request_digest: SecureRandom.hex(32)
      )
    end

    def create_reserved_listing
      ResaleListing.create!(
        event: @event,
        ticket: @ticket,
        ticket_type: @product.ticket_type,
        seller_user: @owner,
        status: "reserved",
        asking_amount_minor: 7_500,
        currency: "ETB",
        seller_acquisition_product_value_minor: 3_000,
        cap_type_snapshot: "fixed",
        fixed_cap_minor_snapshot: 7_500,
        calculated_cap_minor: 7_500,
        resale_count_before: 0,
        max_completed_resales_snapshot: 2,
        resale_cutoff_at: 1.year.from_now,
        activated_at: Time.current,
        commercial_fee_component: @component,
        commercial_fee_schedule_version: @version,
        reserved_order: @buyer_order,
        reserved_at: Time.current,
        reservation_expires_at: 1.hour.from_now,
        idempotency_key: "listing-#{SecureRandom.hex(8)}"
      )
    end

    def create_buyer_order_item
      Orders::OrderItem.create!(
        order: @buyer_order,
        event_product: @product,
        registration: @buyer_registration,
        resale_listing_id: @listing.id,
        name_snapshot: @product.name,
        type_snapshot: "ticket",
        quantity: 1,
        admissions_per_unit_snapshot: 1,
        base_currency: "ETB",
        base_unit_amount_minor: 7_500,
        charge_currency: "ETB",
        charge_unit_amount_minor: 7_500,
        exchange_rate: 1,
        discount_minor: 0,
        total_minor: 7_500,
        fulfillment_status: "fulfilled"
      )
    end

    def sale_attributes
      {
        resale_listing: @listing,
        event: @event,
        ticket: @ticket,
        seller_user: @owner,
        buyer_user: @buyer,
        buyer_registration: @buyer_registration,
        buyer_order: @buyer_order,
        buyer_order_item: @buyer_order_item,
        accepted_payment: @accepted_payment,
        seller_acquisition_order_item: @ticket.order_item,
        resale_number: 1,
        gross_amount_minor: 7_500,
        currency: "ETB",
        marketplace_fee_minor: 500,
        seller_proceeds_minor: 7_000,
        commercial_fee_component: @component,
        commercial_fee_schedule_version: @version,
        fee_calculation_type: "fixed",
        fee_basis_type: "accepted_gross",
        fee_fixed_amount_minor: 500,
        fee_rate_bps: 0,
        status: "completed",
        completed_at: Time.current,
        idempotency_key: "sale-#{SecureRandom.hex(8)}"
      }
    end

    def build_sale(overrides = {})
      ResaleSale.new(sale_attributes.merge(overrides))
    end

    def create_sale!(overrides = {})
      build_sale(overrides).tap(&:save!)
    end
  end
end
