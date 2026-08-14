# frozen_string_literal: true

require "test_helper"

module Ticketing
  module ManualLookup
    class ByPhoneTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup do
        setup_package_workflow(admissions_per_unit: 2)
        prepare_scanner_lookup
      end

      test "normalizes an Ethiopian local phone to the indexed E.164 hash" do
        result = lookup(raw_phone: "0911000003")

        assert_predicate result, :success?, result.error&.message
        assert_equal "success", result.value.status
        assert_equal "phone", result.value.checkin.lookup_via
        assert_equal "phone_dead", result.value.checkin.reason_code
      end

      test "requires the operator to disambiguate multiple tickets" do
        create_second_ticket
        entries = Ticketing::AttendeeIndexEntry.active.where(event_id: @event.id).to_a

        result = lookup(raw_phone: "0911000003")

        assert_predicate result, :success?, result.error&.message
        assert_equal "multiple_matches", result.value.status
        assert_equal entries.length, result.value.matches.length
        assert_nil result.value.checkin
        assert_equal entries.map(&:credential_id).map(&:to_s).sort,
          result.value.matches.map { |match| match.fetch(:credential_id).to_s }.sort
      end

      test "selected phone matches still use the shared admission validator" do
        create_second_ticket
        selected = Ticketing::AttendeeIndexEntry.active.find_by!(ticket_id: @ticket.id)

        result = lookup(raw_phone: "0911000003", selected_credential_id: selected.credential_id)

        assert_predicate result, :success?, result.error&.message
        assert_equal "success", result.value.checkin.result
        assert_equal selected.credential_id, result.value.checkin.credential_id
      end

      test "rejects a phone that is not in the canonical Ethiopian format" do
        result = lookup(raw_phone: "not-a-phone")

        assert_predicate result, :failure?
        assert_equal "invalid_phone", result.error.code
      end

      private

      def prepare_scanner_lookup
        @product_access = @product.product_accesses.first
        @event_date = @product_access.event_date
        @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
        @device = Ticketing::ScannerDevice.create!(
          organization: @event.organization,
          device_identifier: "manual-phone-#{SecureRandom.hex(4)}",
          token_digest: Ticketing::ScannerDevice.token_digest_for(token: SecureRandom.hex(32))
        )
        @assignment = Ticketing::ScannerDeviceAssignment.create!(
          scanner_device: @device,
          event: @event,
          assigned_by: @manager
        )
      end

      def lookup(raw_phone:, selected_credential_id: nil)
        ByPhone.call(
          raw_phone:,
          selected_credential_id:,
          event: @event,
          product_access: @product_access,
          assignment: @assignment,
          operator: @manager,
          reason_code: "phone_dead",
          client_scan_id: SecureRandom.uuid,
          scanned_at: @event_date.starts_at + 1.minute
        )
      end

      def create_second_ticket
        original_product = @product
        original_registration = @registration
        @product = create_package_product(admissions_per_unit: 2, delegation_enabled: true, transferable: true)
        @registration = create_confirmed_registration
        create_issued_ticket
      ensure
        @product = original_product
        @registration = original_registration
      end
    end
  end
end
