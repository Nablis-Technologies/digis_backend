# frozen_string_literal: true

require "test_helper"

module Ticketing
  class TicketTransferTest < ActiveSupport::TestCase
    include Ticketing::PackageWorkflowTestHelpers

    setup { setup_package_workflow(admissions_per_unit: 1) }

    test "requires one pending transfer per ticket and preserves accepted version evidence" do
      assert Ticketing::TicketTransfer::STATUSES.include?("pending")
      assert Ticketing::TicketTransfer::STATUSES.include?("accepted")
      assert_includes Ticketing::TicketTransfer.column_names, "token_digest"
      assert_includes Ticketing::TicketTransfer.column_names, "token_ciphertext"
      assert_includes Ticketing::TicketTransfer.column_names, "previous_version"
      assert_includes Ticketing::TicketTransfer.column_names, "new_version"
    end

    test "encrypts the delivery token instead of exposing it in stored attributes" do
      transfer = @ticket.ticket_transfers.new(
        from_user: @owner,
        to_user: @recipient,
        initiated_by: @owner,
        token_digest: Ticketing::TicketTransfer.token_digest_for(token: "transfer-secret"),
        previous_version: @ticket.credential_version,
        status: "pending",
        expires_at: 1.day.from_now
      )
      transfer.token = "transfer-secret"
      transfer.save!

      assert_equal "transfer-secret", transfer.token
      stored = Ticketing::TicketTransfer.connection.select_value(
        "SELECT token_ciphertext FROM ticketing_ticket_transfers WHERE id = '#{transfer.id}'"
      )
      refute_equal "transfer-secret", stored
    end

    test "does not permit an accepted transfer without its recipient and new version" do
      transfer = Ticketing::TicketTransfer.new(
        from_user_id: SecureRandom.uuid,
        to_user_id: SecureRandom.uuid,
        initiated_by_id: SecureRandom.uuid,
        token_digest: "a" * 64,
        status: "accepted",
        previous_version: 1,
        expires_at: 1.day.from_now
      )

      transfer.send(:lifecycle_timestamps_match)
      assert_includes transfer.errors.attribute_names, :new_version
      assert_includes transfer.errors.attribute_names, :accepted_at
    end
  end
end
