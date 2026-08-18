# frozen_string_literal: true

require "test_helper"

module Ticketing
  class TicketTypeTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @product = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "VIP", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      @ticket_type = @product.ticket_type
    end

    test "audience, approval_mode, and date_selection allowlists" do
      @ticket_type.audience = "nope"
      @ticket_type.approval_mode = "nope"
      @ticket_type.date_selection = "nope"
      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:audience], "is not included in the list"
      assert_includes @ticket_type.errors[:approval_mode], "is not included in the list"
      assert_includes @ticket_type.errors[:date_selection], "is not included in the list"
    end

    test "admissions_per_unit must be positive" do
      @ticket_type.admissions_per_unit = 0
      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:admissions_per_unit], "must be greater than or equal to 1"
    end

    test "transfer and resale cutoffs must be non-negative" do
      @ticket_type.transfer_cutoff_seconds_before_start = -1
      @ticket_type.resale_cutoff_seconds_before_start = -1
      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:transfer_cutoff_seconds_before_start], "must be greater than or equal to 0"
      assert_includes @ticket_type.errors[:resale_cutoff_seconds_before_start], "must be greater than or equal to 0"
    end

    test "entry_validation_mode and delegation_validation_mode allowlists and delegation/transfer flags" do
      @ticket_type.entry_validation_mode = "face"
      @ticket_type.delegation_validation_mode = "weird"
      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:entry_validation_mode], "is not included in the list"
      assert_includes @ticket_type.errors[:delegation_validation_mode], "is not included in the list"
    end

    test "transferable may be set as an override" do
      @ticket_type.transferable = true
      assert @ticket_type.valid?
    end

    test "resale cap is mutually exclusive between fixed and percentage" do
      @ticket_type.resale_enabled = true
      @ticket_type.resale_price_cap_type = "fixed"
      @ticket_type.resale_fixed_cap_minor = 5000
      @ticket_type.resale_fixed_cap_currency = "ETB"
      @ticket_type.resale_percentage_cap_bps = 1000
      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:resale_percentage_cap_bps], "must be blank for fixed cap"
    end

    test "resale fixed cap requires amount and currency" do
      @ticket_type.resale_enabled = true
      @ticket_type.resale_price_cap_type = "fixed"
      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:resale_fixed_cap_minor], "is required for fixed cap"
      assert_includes @ticket_type.errors[:resale_fixed_cap_currency], "is required for fixed cap"
    end

    test "resale percentage cap requires basis points" do
      @ticket_type.resale_enabled = true
      @ticket_type.resale_price_cap_type = "percentage"
      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:resale_percentage_cap_bps], "is required for percentage cap"
    end

    test "max_completed_resales must be positive" do
      @ticket_type.max_completed_resales = 0
      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:max_completed_resales], "must be greater than or equal to 1"
    end

    test "package size is immutable once commitments exist" do
      @ticket_type.stubs(:committed?).returns(true)
      @ticket_type.admissions_per_unit = 4
      assert @ticket_type.invalid?
      assert_includes @ticket_type.errors[:admissions_per_unit], "cannot be changed after commitments exist"
    end

    test "package size can change before any commitments" do
      @ticket_type.admissions_per_unit = 4
      assert @ticket_type.valid?
    end

    test "package size is immutable once an order item references the ticket product" do
      order = Orders::Order.create!(
        event: @event,
        buyer_user: core_users(:attendee),
        sales_channel: "online",
        status: "draft",
        charge_currency: "ETB",
        commercial_signature: "a" * 64,
        subtotal_minor: 10_000,
        discount_minor: 0,
        subsidy_minor: 0,
        fee_minor: 0,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: 10_000,
        settlement_currency: "ETB",
        settlement_total_minor: 10_000,
        exchange_rate: 1,
        exchange_rate_source: "same_currency",
        exchange_rate_expires_at: 10.minutes.from_now,
        expires_at: 10.minutes.from_now,
        idempotency_key_digest: SecureRandom.hex(32),
        creation_request_digest: SecureRandom.hex(32)
      )
      Orders::OrderItem.create!(
        order:,
        event_product: @product,
        name_snapshot: @product.name,
        type_snapshot: "ticket",
        quantity: 1,
        admissions_per_unit_snapshot: @ticket_type.admissions_per_unit,
        base_currency: "ETB",
        base_unit_amount_minor: 10_000,
        charge_currency: "ETB",
        charge_unit_amount_minor: 10_000,
        discount_minor: 0,
        total_minor: 10_000,
        fulfillment_status: "pending"
      )

      @ticket_type.admissions_per_unit = 4

      assert_not @ticket_type.valid?
      assert_includes @ticket_type.errors[:admissions_per_unit],
        I18n.t("ticketing.ticket_type.errors.admissions_per_unit_locked")
    end
  end
end
