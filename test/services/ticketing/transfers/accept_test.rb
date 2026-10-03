# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Transfers
    class AcceptTest < ActiveSupport::TestCase
      include Ticketing::PackageWorkflowTestHelpers

      setup { setup_package_workflow }

      test "initiates a pending transfer without changing current ownership" do
        initiated = Ticketing::Transfers::Initiate.call(
          ticket: @ticket,
          actor: @owner,
          phone: @recipient.phone,
          idempotency_key: "transfer-initiate"
        )

        assert_predicate initiated, :success?, initiated.error&.message
        transfer = initiated.value.transfer
        assert_equal "pending", transfer.status
        assert_equal @owner.id, @ticket.reload.owner_user_id
        assert_equal 1, @ticket.current_credential_generation.version
        assert initiated.value.token.present?
        assert_equal 64, transfer.token_digest.length
        assert_equal initiated.value.token, transfer.reload.token
        stored_token = Ticketing::TicketTransfer.connection.select_value(
          "SELECT token_ciphertext FROM ticketing_ticket_transfers WHERE id = '#{transfer.id}'"
        )
        refute_equal initiated.value.token, stored_token
      end

      test "accepts only by the resolved recipient and creates a new group generation" do
        initiated = initiate_transfer

        wrong = Ticketing::Transfers::Accept.call(token: initiated.value.token, actor: @other_user)
        assert_predicate wrong, :failure?
        assert_equal "transfer_recipient_mismatch", wrong.error.code

        accepted = Ticketing::Transfers::Accept.call(token: initiated.value.token, actor: @recipient)

        assert_predicate accepted, :success?, accepted.error&.message
        assert_equal "accepted", accepted.value.status
        assert_equal 2, accepted.value.new_version
        assert_equal @recipient.id, @ticket.reload.owner_user_id
        assert_equal "group", @ticket.current_credential_generation.reload.mode
        assert_equal "revoked", @ticket.credential_generations.find_by(version: 1).status

        replayed_by_wrong_user = Ticketing::Transfers::Accept.call(
          token: initiated.value.token,
          actor: @other_user
        )
        assert_predicate replayed_by_wrong_user, :failure?
        assert_equal "transfer_recipient_mismatch", replayed_by_wrong_user.error.code
      end

      test "accepts an incoming transfer by ID for the verified recipient" do
        initiated = initiate_transfer

        accepted = Ticketing::Transfers::Accept.call(
          transfer_id: initiated.value.transfer.id,
          actor: @recipient
        )

        assert_predicate accepted, :success?, accepted.error&.message
        assert_equal "accepted", accepted.value.status
        assert_equal @recipient.id, @ticket.reload.owner_user_id
        assert_equal 2, @ticket.credential_version
      end

      test "a valid token cannot accept a different transfer ID" do
        initiated = initiate_transfer

        result = Ticketing::Transfers::Accept.call(
          transfer_id: SecureRandom.uuid,
          token: initiated.value.token,
          actor: @recipient
        )

        assert_predicate result, :failure?
        assert_equal "transfer_invalid", result.error.code
        assert_equal "pending", initiated.value.transfer.reload.status
        assert_equal @owner.id, @ticket.reload.owner_user_id
      end

      test "does not resolve an incoming transfer ID for another user" do
        initiated = initiate_transfer

        rejected = Ticketing::Transfers::Accept.call(
          transfer_id: initiated.value.transfer.id,
          actor: @other_user
        )

        assert_predicate rejected, :failure?
        assert_equal "transfer_invalid", rejected.error.code
        assert_equal "pending", initiated.value.transfer.reload.status
        assert_equal @owner.id, @ticket.reload.owner_user_id
      end

      test "re-evaluates a rescheduled cutoff at acceptance" do
        initiated = initiate_transfer
        event_date = @product.product_accesses.first.event_date
        event_date.update!(starts_at: 1.hour.ago, ends_at: 1.hour.from_now)

        accepted = Ticketing::Transfers::Accept.call(token: initiated.value.token, actor: @recipient)

        assert_predicate accepted, :failure?
        assert_equal "transfer_cutoff_passed", accepted.error.code
        assert_equal "pending", initiated.value.transfer.reload.status
        assert_equal @owner.id, @ticket.reload.owner_user_id
      end

      test "cancels a pending transfer and keeps the original credential valid" do
        initiated = initiate_transfer

        cancelled = Ticketing::Transfers::Cancel.call(
          transfer: initiated.value.transfer,
          actor: @owner,
          idempotency_key: "transfer-cancel"
        )

        assert_predicate cancelled, :success?, cancelled.error&.message
        assert_equal "cancelled", cancelled.value.status
        assert_equal "active", @ticket.current_credential_generation.reload.status
        assert_equal @owner.id, @ticket.reload.owner_user_id
      end

      private

      def initiate_transfer
        Ticketing::Transfers::Initiate.call(
          ticket: @ticket,
          actor: @owner,
          phone: @recipient.phone,
          idempotency_key: "transfer-initiate-#{SecureRandom.hex(4)}"
        ).tap { |result| assert_predicate result, :success?, result.error&.message }
      end
    end
  end
end
