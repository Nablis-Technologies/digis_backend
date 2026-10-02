# frozen_string_literal: true

require "test_helper"

module Ticketing
  class TicketsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::PackageWorkflowTestHelpers

    setup { setup_package_workflow(admissions_per_unit: 2) }

    test "returns the owner's ticket with static QR and PNR wallet data" do
      get "/tickets", headers: headers_for(@owner), as: :json

      assert_response :success
      ticket = response.parsed_body.fetch("data").sole
      assert_equal @ticket.id, ticket.fetch("id")
      assert_equal @event.title, ticket.dig("event", "title")
      assert_equal @product.name, ticket.dig("product", "name")
      assert_equal @product.ticket_type.id, ticket.dig("ticket_type", "id")
      assert_equal 1, ticket.fetch("credentials").length
      credential = ticket.fetch("credentials").first
      assert credential.fetch("qr_token").present?
      assert_match(/\A[23456789CFGHJKMNPQRVWX]{8}\z/, credential.fetch("lookup_code"))
      assert_equal 2, ticket.fetch("admission_slots").length
      assert_nil ticket.fetch("pending_transfer")
      %w[payment provider holder_name commercial_signature].each do |field|
        refute ticket.key?(field), "wallet response leaked #{field}"
      end
    end

    test "shows a safe pending-transfer summary only while the transfer is unexpired and pending" do
      initiated = Ticketing::Transfers::Initiate.call(
        ticket: @ticket,
        actor: @owner,
        phone: @recipient.phone,
        idempotency_key: "wallet-pending-transfer-#{SecureRandom.hex(4)}"
      )
      assert_predicate initiated, :success?, initiated.error&.message
      transfer = initiated.value.transfer

      get "/tickets", headers: headers_for(@owner), as: :json

      assert_response :success
      ticket = response.parsed_body.fetch("data").sole
      pending = ticket.fetch("pending_transfer")
      assert_equal %w[expires_at id status], pending.keys.sort
      assert_equal transfer.id, pending.fetch("id")
      assert_equal "pending", pending.fetch("status")
      assert_equal transfer.expires_at.as_json, pending.fetch("expires_at")
      refute_includes response.body, initiated.value.token
      refute_includes response.body, transfer.token_digest
      refute_includes response.body, @recipient.phone

      cancelled = Ticketing::Transfers::Cancel.call(
        transfer:,
        actor: @owner,
        idempotency_key: "wallet-cancel-transfer-#{SecureRandom.hex(4)}"
      )
      assert_predicate cancelled, :success?, cancelled.error&.message

      get "/tickets", headers: headers_for(@owner), as: :json
      assert_response :success
      assert_nil response.parsed_body.dig("data", 0, "pending_transfer")

      declined = Ticketing::Transfers::Initiate.call(
        ticket: @ticket,
        actor: @owner,
        phone: @recipient.phone,
        idempotency_key: "wallet-decline-transfer-#{SecureRandom.hex(4)}"
      )
      assert_predicate declined, :success?, declined.error&.message
      decline_result = Ticketing::Transfers::Decline.call(
        transfer: declined.value.transfer,
        actor: @recipient,
        idempotency_key: "wallet-decline-transfer-result-#{SecureRandom.hex(4)}"
      )
      assert_predicate decline_result, :success?, decline_result.error&.message

      get "/tickets", headers: headers_for(@owner), as: :json
      assert_response :success
      assert_nil response.parsed_body.dig("data", 0, "pending_transfer")

      expired = Ticketing::Transfers::Initiate.call(
        ticket: @ticket,
        actor: @owner,
        phone: @recipient.phone,
        idempotency_key: "wallet-expire-transfer-#{SecureRandom.hex(4)}"
      )
      assert_predicate expired, :success?, expired.error&.message
      expired.value.transfer.update_columns(expires_at: 1.second.ago)

      get "/tickets", headers: headers_for(@owner), as: :json
      assert_response :success
      assert_nil response.parsed_body.dig("data", 0, "pending_transfer")

      Ticketing::ExpireTransfersJob.perform_now
      assert_equal "expired", expired.value.transfer.reload.status

      accepted = Ticketing::Transfers::Initiate.call(
        ticket: @ticket,
        actor: @owner,
        phone: @recipient.phone,
        idempotency_key: "wallet-accept-transfer-#{SecureRandom.hex(4)}"
      )
      assert_predicate accepted, :success?, accepted.error&.message
      accepted_result = Ticketing::Transfers::Accept.call(token: accepted.value.token, actor: @recipient)
      assert_predicate accepted_result, :success?, accepted_result.error&.message

      get "/tickets", headers: headers_for(@recipient), as: :json
      assert_response :success
      recipient_ticket = response.parsed_body.fetch("data").sole
      assert_equal @ticket.id, recipient_ticket.fetch("id")
      assert_nil recipient_ticket.fetch("pending_transfer")
    end

    test "requires authentication" do
      get "/tickets", as: :json

      assert_response :unauthorized
    end

    test "returns only the current user's tickets" do
      get "/tickets", headers: headers_for(@other_user), as: :json

      assert_response :success
      assert_empty response.parsed_body.fetch("data")
    end

    test "repeats the same static QR until a credential generation changes" do
      get "/tickets", headers: headers_for(@owner), as: :json
      first_qr = response.parsed_body.dig("data", 0, "credentials", 0, "qr_token")

      get "/tickets", headers: headers_for(@owner), as: :json
      second_qr = response.parsed_body.dig("data", 0, "credentials", 0, "qr_token")

      assert_equal first_qr, second_qr
    end

    test "does not return a usable QR for a suspended ticket" do
      @ticket.update!(status: "suspended")

      get "/tickets", headers: headers_for(@owner), as: :json

      assert_response :success
      credentials = response.parsed_body.dig("data", 0, "credentials")
      assert credentials.all? { |credential| credential["qr_token"].nil? }
    end

    test "does not return credentials from a revoked generation" do
      @ticket.current_credential_generation.update_columns(status: "revoked", revoked_at: Time.current)

      get "/tickets", headers: headers_for(@owner), as: :json

      assert_response :success
      assert_empty response.parsed_body.dig("data", 0, "credentials")
    end

    private

    def headers_for(user)
      { "Authorization" => "Bearer #{Core::TokenService.issue(Core::TokenService.access_token_payload(user))}" }
    end
  end
end
