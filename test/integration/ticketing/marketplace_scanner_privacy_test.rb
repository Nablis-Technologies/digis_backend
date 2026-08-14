# frozen_string_literal: true

require "test_helper"

module Ticketing
  class MarketplaceScannerPrivacyTest < ActionDispatch::IntegrationTest
    test "scanner contract does not expose marketplace economics" do
      payload = Ticketing::ScannerSyncSerializer.call(
        contract_version: "v1",
        event_id: SecureRandom.uuid,
        sync_mode: "full",
        versions: { revocations: 0, attendee_index: 0, schedule: 0, reversals: 0 },
        signing_keys: {},
        package_revocations: { version: 0, changed: [] },
        credential_revocations: { version: 0, changed: [] },
        attendee_index: {
          version: 0,
          changed: [
            {
              credential_id: SecureRandom.uuid,
              ticket_id: SecureRandom.uuid,
              lookup_code: "lookup",
              entry_limit: 1,
              credential_mode: "group",
              generation_version: 1,
              ticket_type: "ticket",
              index_version: 1,
              removed: false,
              asking_amount_minor: 2_500,
              seller_acquisition_product_value_minor: 2_000,
              marketplace_fee_minor: 300,
              seller_proceeds_minor: 2_200,
              payout_status: "pending"
            }
          ]
        },
        schedule: { version: 0, changed: [] },
        server_use_ids: [],
        admission_use_reversals: { version: 0, changed: [] }
      )

      serialized = JSON.generate(payload)
      %w[asking_amount_minor seller_acquisition_product_value_minor marketplace_fee_minor
         seller_proceeds_minor payout_status resale_listing_id].each do |field|
        assert_not_includes serialized, field
      end
    end
  end
end
