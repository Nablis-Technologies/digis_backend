# frozen_string_literal: true

require "test_helper"

module Marketplace
  class ResaleListingTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers
    include Commercial::FeeDefinitionTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1, delegation_enabled: false)
      @schedule = create_schedule(code: "resale_listing_#{SecureRandom.hex(4)}")
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
    end

    test "rejects competing cap snapshots" do
      listing = build_listing(percentage_cap_bps_snapshot: 5_000)

      assert_not listing.valid?
      assert_includes listing.errors.attribute_names, :percentage_cap_bps_snapshot
    end

    test "rejects asking amount above the calculated cap" do
      listing = build_listing(asking_amount_minor: 7_501, calculated_cap_minor: 7_500)

      assert_not listing.valid?
      assert_includes listing.errors.attribute_names, :asking_amount_minor
    end

    test "rejects reservation metadata on an active listing" do
      listing = build_listing(
        reserved_order_id: @ticket.order_item.order_id,
        reserved_at: Time.current,
        reservation_expires_at: 1.hour.from_now
      )

      assert_not listing.valid?
      assert_includes listing.errors.attribute_names, :reserved_order_id
    end

    test "database rejects a second active listing for one ticket" do
      create_listing!

      assert_raises(ActiveRecord::RecordNotUnique) do
        create_listing!
      end
    end

    test "database rejects mixed cap snapshots even when validations are bypassed" do
      listing = create_listing!

      assert_raises(ActiveRecord::StatementInvalid) do
        listing.update_columns(percentage_cap_bps_snapshot: 5_000)
      end
    end

    test "database rejects an asking amount above the cap" do
      listing = create_listing!

      assert_raises(ActiveRecord::StatementInvalid) do
        listing.update_columns(asking_amount_minor: 7_501)
      end
    end

    private

    def listing_attributes
      {
        event: @event,
        ticket: @ticket,
        ticket_type: @product.ticket_type,
        seller_user: @owner,
        status: "active",
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
        idempotency_key: "listing-#{SecureRandom.hex(8)}"
      }
    end

    def build_listing(overrides = {})
      ResaleListing.new(listing_attributes.merge(overrides))
    end

    def create_listing!(overrides = {})
      build_listing(overrides).tap(&:save!)
    end
  end
end
