# frozen_string_literal: true

require "test_helper"

module Ticketing
  class QrManualLookupParityTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 2)
      @entry = @ticket.current_credential_generation.credentials.first.attendee_index_entry
      @event_date = @product.product_accesses.first.event_date
      @event_date.update_columns(starts_at: 1.hour.ago, ends_at: 2.hours.from_now)
    end

    test "QR and indexed lookup reconstruct identical admission claims" do
      qr_claims = Ticketing::Qr::Verifier.call(
        token: @ticket.current_credential_generation.credentials.first.qr_token
      ).value
      indexed_claims = Ticketing::CredentialClaims.from_index_entry(
        @entry,
        expires_at: @event_date.ends_at
      )

      assert_equal qr_claims.tid, indexed_claims.tid
      assert_equal qr_claims.eid, indexed_claims.eid
      assert_equal qr_claims.mode, indexed_claims.mode
      assert_equal qr_claims.slots, indexed_claims.slots
      assert_equal qr_claims.entry_limit, indexed_claims.entry_limit
      assert_equal qr_claims.v, indexed_claims.v
      assert_equal qr_claims.accesses, indexed_claims.accesses
    end
  end
end
