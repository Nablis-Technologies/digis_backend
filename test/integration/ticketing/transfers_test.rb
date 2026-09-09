# frozen_string_literal: true

require "test_helper"

module Ticketing
  class TransfersTest < ActionDispatch::IntegrationTest
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1)
      @owner_token = Core::TokenService.issue(Core::TokenService.access_token_payload(@owner))
      @recipient_token = Core::TokenService.issue(Core::TokenService.access_token_payload(@recipient))
      @other_token = Core::TokenService.issue(Core::TokenService.access_token_payload(@other_user))

      @owner_headers = {
        "Authorization" => "Bearer #{@owner_token}",
        "Content-Type" => "application/json"
      }
      @recipient_headers = {
        "Authorization" => "Bearer #{@recipient_token}",
        "Content-Type" => "application/json"
      }
      @other_headers = {
        "Authorization" => "Bearer #{@other_token}",
        "Content-Type" => "application/json"
      }
    end

    # --- INITIATE (/tickets/:ticket_id/transfers) ---

    test "owner can initiate transfer and receives raw token" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone, reason: "Gift" }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "initiate-transfer-test-1")

      assert_response :created
      data = response.parsed_body.fetch("data")
      transfer_data = data.fetch("transfer")
      raw_token = data.fetch("token")

      assert_equal "pending", transfer_data.fetch("status")
      assert_equal @ticket.id, transfer_data.fetch("ticket_id")
      assert_predicate raw_token, :present?

      transfer = Ticketing::TicketTransfer.find(transfer_data.fetch("id"))
      assert_equal transfer.token_digest, Ticketing::TicketTransfer.token_digest_for(token: raw_token)
      assert_equal raw_token, transfer.token

      assert Core::OutboxEvent.exists?(
        aggregate_type: "Ticketing::TicketTransfer",
        aggregate_id: transfer.id,
        event_type: "ticketing.ticket_transfer.initiated"
      )
    end

    test "non-owner cannot initiate transfer" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone }.to_json,
        headers: @other_headers.merge("Idempotency-Key" => "non-owner-initiate")

      assert_response :forbidden
    end

    test "cannot initiate transfer without Idempotency-Key header" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone }.to_json,
        headers: @owner_headers

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "cannot initiate self-transfer" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @owner.phone }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "self-transfer-test")

      assert_response :unprocessable_entity
      assert_equal "transfer_recipient_same_as_owner", response.parsed_body.fetch("code")
    end

    test "cannot initiate transfer when another transfer is pending" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "first-transfer")

      assert_response :created

      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @other_user.phone }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "second-transfer")

      assert_response :conflict
      assert_equal "transfer_already_pending", response.parsed_body.fetch("code")
    end

    # --- ACCEPT (/ticket_transfers/:id/accept) ---

    test "authenticated recipient can accept transfer with valid token" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "transfer-for-accept")

      assert_response :created
      transfer_id = response.parsed_body.dig("data", "transfer", "id")
      raw_token = response.parsed_body.dig("data", "token")

      post "/ticket_transfers/#{transfer_id}/accept",
        params: { token: raw_token }.to_json,
        headers: @recipient_headers.merge("Idempotency-Key" => "accept-transfer-1")

      assert_response :success
      assert_equal "accepted", response.parsed_body.dig("data", "status")

      @ticket.reload
      assert_equal @recipient.id, @ticket.owner_user_id
      assert_equal 2, @ticket.credential_version

      assert Core::OutboxEvent.exists?(
        aggregate_type: "Ticketing::TicketTransfer",
        aggregate_id: transfer_id,
        event_type: "ticketing.ticket_transfer.accepted"
      )
    end

    test "accepting with invalid token returns 404" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "transfer-for-bad-accept")

      transfer_id = response.parsed_body.dig("data", "transfer", "id")

      post "/ticket_transfers/#{transfer_id}/accept",
        params: { token: "wrong-token" }.to_json,
        headers: @recipient_headers.merge("Idempotency-Key" => "accept-bad-token")

      assert_response :not_found
    end

    test "non-recipient user cannot accept transfer" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "transfer-for-wrong-user")

      transfer_id = response.parsed_body.dig("data", "transfer", "id")
      raw_token = response.parsed_body.dig("data", "token")

      post "/ticket_transfers/#{transfer_id}/accept",
        params: { token: raw_token }.to_json,
        headers: @other_headers.merge("Idempotency-Key" => "accept-by-wrong-user")

      assert_response :forbidden
    end

    # --- CANCEL (/ticket_transfers/:id/cancel) ---

    test "owner can cancel pending transfer" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "transfer-for-cancel")

      transfer_id = response.parsed_body.dig("data", "transfer", "id")

      post "/ticket_transfers/#{transfer_id}/cancel",
        headers: @owner_headers.merge("Idempotency-Key" => "cancel-transfer-1")

      assert_response :success
      assert_equal "cancelled", response.parsed_body.dig("data", "status")

      transfer = Ticketing::TicketTransfer.find(transfer_id)
      assert_equal "cancelled", transfer.status
      assert_predicate transfer.cancelled_at, :present?

      assert Core::OutboxEvent.exists?(
        aggregate_type: "Ticketing::TicketTransfer",
        aggregate_id: transfer_id,
        event_type: "ticketing.ticket_transfer.cancelled"
      )
    end

    test "non-owner cannot cancel pending transfer" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "transfer-for-nonowner-cancel")

      transfer_id = response.parsed_body.dig("data", "transfer", "id")

      post "/ticket_transfers/#{transfer_id}/cancel",
        headers: @other_headers.merge("Idempotency-Key" => "cancel-by-other")

      assert_response :forbidden
    end

    test "cannot cancel without Idempotency-Key header" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "transfer-for-nokey-cancel")

      transfer_id = response.parsed_body.dig("data", "transfer", "id")

      post "/ticket_transfers/#{transfer_id}/cancel",
        headers: @owner_headers

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    # --- DECLINE (/ticket_transfers/:id/decline) ---

    test "recipient can decline pending transfer" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "transfer-for-decline")

      transfer_id = response.parsed_body.dig("data", "transfer", "id")

      post "/ticket_transfers/#{transfer_id}/decline",
        headers: @recipient_headers.merge("Idempotency-Key" => "decline-transfer-1")

      assert_response :success
      assert_equal "declined", response.parsed_body.dig("data", "status")

      transfer = Ticketing::TicketTransfer.find(transfer_id)
      assert_equal "declined", transfer.status
      assert_predicate transfer.declined_at, :present?

      assert Core::OutboxEvent.exists?(
        aggregate_type: "Ticketing::TicketTransfer",
        aggregate_id: transfer_id,
        event_type: "ticketing.ticket_transfer.declined"
      )
    end

    test "non-recipient cannot decline pending transfer" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "transfer-for-nonrecipient-decline")

      transfer_id = response.parsed_body.dig("data", "transfer", "id")

      post "/ticket_transfers/#{transfer_id}/decline",
        headers: @other_headers.merge("Idempotency-Key" => "decline-by-other")

      assert_response :forbidden
    end

    test "cannot decline without Idempotency-Key header" do
      post "/tickets/#{@ticket.id}/transfers",
        params: { phone: @recipient.phone }.to_json,
        headers: @owner_headers.merge("Idempotency-Key" => "transfer-for-nokey-decline")

      transfer_id = response.parsed_body.dig("data", "transfer", "id")

      post "/ticket_transfers/#{transfer_id}/decline",
        headers: @recipient_headers

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end
  end
end
