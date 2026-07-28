# frozen_string_literal: true

require "test_helper"

module Ticketing
  class TicketTypeTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @product = Catalog::Products::Create.new(
        event: @event,
        attributes: { name: "VIP", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        }
      ).call.value
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
  end
end
