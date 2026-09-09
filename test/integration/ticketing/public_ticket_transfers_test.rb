# frozen_string_literal: true

require "test_helper"

module Ticketing
  class PublicTicketTransfersTest < ActionDispatch::IntegrationTest
    include Ticketing::PackageWorkflowTestHelpers
    include ActiveJob::TestHelper

    setup do
      setup_package_workflow(admissions_per_unit: 1)
      @shadow = Core::User.create!(phone: "+251911000082")
      @token = "public-transfer-token"
      @transfer = @ticket.ticket_transfers.create!(
        from_user: @owner,
        to_user: @shadow,
        initiated_by: @owner,
        token: @token,
        token_digest: Ticketing::TicketTransfer.token_digest_for(token: @token),
        previous_version: @ticket.credential_version,
        status: "pending",
        expires_at: 1.day.from_now
      )
      @delivered_code = nil
      @previous_sender = Rails.application.config.x.phone_verification_sender
      Rails.application.config.x.phone_verification_sender = lambda do |code:, **|
        @delivered_code = code
      end
    end

    teardown do
      Rails.application.config.x.phone_verification_sender = @previous_sender
    end

    test "returns a masked public transfer and accepts a shadow recipient through OTP" do
      get "/public/ticket_transfers/#{@transfer.id}", params: { token: @token }
      assert_response :success
      landing = response.parsed_body.fetch("data")
      assert_equal @transfer.id, landing.fetch("id")
      assert_equal "pending", landing.fetch("status")
      assert_match(/\A\+251\*+82\z/, landing.dig("recipient", "phone"))
      refute_includes landing.dig("recipient", "phone"), "911000082"

      post "/public/ticket_transfers/#{@transfer.id}/request_otp",
        params: { token: @token, phone: @shadow.phone },
        headers: { "Idempotency-Key" => "public-transfer-otp" },
        as: :json

      assert_response :created
      challenge_id = response.parsed_body.dig("data", "challenge_id")
      assert_predicate challenge_id, :present?

      post "/phone_verifications/#{challenge_id}/verify",
        params: { code: @delivered_code },
        headers: { "Idempotency-Key" => "public-transfer-otp-verify" },
        as: :json

      assert_response :success
      verification_token = response.parsed_body.dig("data", "verification_token")
      assert_predicate verification_token, :present?

      post "/public/ticket_transfers/#{@transfer.id}/accept_guest",
        params: {
          token: @token,
          phone: @shadow.phone,
          verification_token:
        },
        headers: { "Idempotency-Key" => "public-transfer-accept" },
        as: :json

      assert_response :success
      data = response.parsed_body.fetch("data")
      assert_equal "accepted", data.dig("transfer", "status")
      assert_equal @shadow.id, @ticket.reload.owner_user_id
      assert_equal 2, @ticket.current_credential_generation.reload.version
      assert_match(%r{/public/tickets/#{@ticket.id}\?view_token=|/t-[a-z0-9]{6}\z}, data.fetch("ticket_view_url"))
      assert data.dig("ticket", "credentials").any?
      assert_nil data["access_token"]
    end

    test "requires the transfer token and idempotency key" do
      get "/public/ticket_transfers/#{@transfer.id}", params: { token: "wrong" }

      assert_response :not_found
      assert_equal "invalid_transfer", response.parsed_body.fetch("code")

      post "/public/ticket_transfers/#{@transfer.id}/request_otp",
        params: { token: @token, phone: @shadow.phone }, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "upgrades a shadow recipient when a password is supplied and rejects a conflicting replay" do
      post "/public/ticket_transfers/#{@transfer.id}/request_otp",
        params: { token: @token, phone: @shadow.phone },
        headers: { "Idempotency-Key" => "public-transfer-password-otp" },
        as: :json
      challenge_id = response.parsed_body.dig("data", "challenge_id")

      post "/phone_verifications/#{challenge_id}/verify",
        params: { code: @delivered_code },
        headers: { "Idempotency-Key" => "public-transfer-password-verify" },
        as: :json
      verification_token = response.parsed_body.dig("data", "verification_token")

      payload = {
        token: @token,
        phone: @shadow.phone,
        verification_token:,
        password: "password123",
        password_confirmation: "password123"
      }
      headers = { "Idempotency-Key" => "public-transfer-password-accept" }

      post "/public/ticket_transfers/#{@transfer.id}/accept_guest", params: payload, headers:, as: :json

      assert_response :success
      assert response.parsed_body.dig("data", "access_token").present?
      assert response.parsed_body.dig("data", "refresh_token").present?
      assert @shadow.reload.verified_at.present?

      post "/public/ticket_transfers/#{@transfer.id}/accept_guest",
        params: payload.merge(password: "different123", password_confirmation: "different123"),
        headers:,
        as: :json

      assert_response :conflict
      assert_equal "transfer_conflict", response.parsed_body.fetch("code")
    end
  end
end
