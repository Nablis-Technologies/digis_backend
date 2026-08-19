# frozen_string_literal: true

require "json"
require "test_helper"

module Ticketing
  module Performance
    class ScannerSyncPerformanceTest < ActiveSupport::TestCase
      CONTRACT_PATH = Rails.root.join("test/fixtures/files/ticketing/scanner_sync_contract_v1.json")

      setup do
        skip "set EVENT_PLATFORM_PERFORMANCE=1 to run throughput benchmarks" unless
          ENV["EVENT_PLATFORM_PERFORMANCE"] == "1"
      end

      test "serializes a production-shaped 50K attendee snapshot within the contract budget" do
        contract = load_contract
        count = contract.dig(:performance, :snapshot_attendee_entries)
        payload = payload_with_attendee_entries(contract.fetch(:sample_payload), count)

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @snapshot = Ticketing::ScannerSyncSerializer.call(payload)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        assert_equal count, @snapshot.fetch("attendee_index").fetch("changed").length
        assert_operator elapsed, :<, snapshot_budget(contract)
      end

      test "serializes a production-shaped 50K attendee delta within the contract budget" do
        contract = load_contract
        count = contract.dig(:performance, :snapshot_attendee_entries)
        payload = payload_with_attendee_entries(contract.fetch(:sample_payload), count)
                       .merge(sync_mode: "delta")

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @delta = Ticketing::ScannerSyncSerializer.call(payload)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        assert_equal "delta", @delta.fetch("sync_mode")
        assert_equal count, @delta.fetch("attendee_index").fetch("changed").length
        assert_operator elapsed, :<, snapshot_budget(contract)
      end

      test "serializes a production-shaped 500-scan upload response within the contract budget" do
        contract = load_contract
        count = contract.dig(:performance, :upload_scans)
        payload = payload_with_upload_results(contract.fetch(:sample_payload), count)

        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        JSON.generate(payload)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

        assert_equal count, payload.fetch(:results).length
        assert_operator elapsed, :<, contract.dig(:performance, :upload_seconds)
      end

      private

      def load_contract
        @contract ||= JSON.parse(File.read(CONTRACT_PATH)).deep_symbolize_keys
      end

      def snapshot_budget(contract)
        budget_key = ENV["CI"].present? ? :snapshot_seconds_ci : :snapshot_seconds
        contract.dig(:performance, budget_key)
      end

      def payload_with_attendee_entries(sample, count)
        sample.deep_symbolize_keys.merge(
          attendee_index: {
            version: 4,
            changed: Array.new(count) do |index|
              {
                credential_id: "credential-#{index}",
                ticket_id: "ticket-#{index}",
                lookup_code: format("PNR%05d", index),
                phone_hash: "phone-hash-#{index}",
                owner_phone_hash: "owner-hash-#{index}",
                slot_positions: [ 1 ],
                credential_mode: "individual",
                generation_version: 1,
                entry_limit: 1,
                ticket_type: "general",
                ticket_type_label: "General",
                perks: [],
                product_access_ids: [ "access-1" ],
                entry_validation_mode: "qr",
                index_version: index + 1,
                removed: false
              }
            end
          }
        )
      end

      def payload_with_upload_results(sample, count)
        sample.deep_symbolize_keys.merge(
          results: Array.new(count) do |index|
            {
              client_scan_id: "scan-#{index}",
              server_checkin_id: "checkin-#{index}",
              result: "success",
              credential_id: "credential-#{index}",
              credential_version: 1,
              product_access_id: "access-1",
              event_date_id: "date-1",
              server_use_ids: [ "use-#{index}" ],
              admission_uses: [
                { id: "use-#{index}", admission_slot_id: "slot-#{index}", usage_number: 1 }
              ]
            }
          end
        )
      end
    end
  end
end
