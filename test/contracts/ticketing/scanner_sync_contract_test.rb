# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Contracts
    class ScannerSyncContractTest < ActiveSupport::TestCase
      CONTRACT_PATH = Rails.root.join("test/fixtures/files/ticketing/scanner_sync_contract_v1.json")

      test "serializer preserves the sync vocabulary and removes forbidden data" do
        contract = JSON.parse(File.read(CONTRACT_PATH))
        payload = Ticketing::ScannerSyncSerializer.new(contract.fetch("sample_payload")).as_json

        assert_equal contract.fetch("required_keys").sort, payload.keys.map(&:to_s).sort
        contract.fetch("forbidden_keys").each do |key|
          refute_includes JSON.generate(payload), key
        end

        changed = payload.fetch("attendee_index").fetch("changed")
        assert_equal true, changed.first.fetch("removed")
        assert_equal false, changed.last.fetch("removed")
      end

      test "contract declares atomic local apply order and explicit scale budgets" do
        contract = JSON.parse(File.read(CONTRACT_PATH))

        assert_equal 1, contract.fetch("contract_version")
        assert_equal %w[
          server_use_ids
          package_revocations
          credential_revocations
          attendee_tombstones
          attendee_additions
          admission_use_reversals
          schedule_and_zone_policies
          cursor_versions
        ], contract.fetch("local_apply_order")
        assert_equal 50_000, contract.dig("performance", "snapshot_attendee_entries")
        assert_equal 500, contract.dig("performance", "upload_scans")
        assert_operator contract.dig("performance", "snapshot_seconds"), :>, 0
        assert_operator contract.dig("performance", "upload_seconds"), :>, 0
        assert_equal "single_transaction", contract.dig("offline_behavior", "apply_transaction")
        assert_equal "last", contract.dig("offline_behavior", "cursor_commit_position")
      end
    end
  end
end
