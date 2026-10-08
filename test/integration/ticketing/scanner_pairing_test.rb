# frozen_string_literal: true

require "test_helper"

module Ticketing
  class ScannerPairingTest < ActionDispatch::IntegrationTest
    setup do
      @event = events_events(:ready_listing)
      @creator = core_users(:core_admin)
      @installation_id = "pwa-install-#{SecureRandom.hex(8)}"
      @idempotency_key = "scanner-pair-#{SecureRandom.hex(8)}"
      @invitation = create_invitation
      @payload = {
        pairing_token: @invitation.token,
        pairing_method: "sms_link",
        installation_id: @installation_id,
        device_name: "Main Gate Android"
      }
    end

    test "pairs with only the invitation capability and returns a no-store scoped bearer" do
      assert_difference -> { ScannerSession.count }, 1 do
        post "/scanner/pair",
             params: @payload,
             headers: { "Idempotency-Key" => @idempotency_key },
             as: :json
      end

      assert_response :created
      assert_includes response.headers.fetch("Cache-Control"), "no-store"
      data = response.parsed_body.fetch("data")
      assert_match(/\A[0-9a-f]{64}\z/, data.fetch("scanner_session_token"))
      assert_equal @event.id, data.dig("event", "id")
      assert_equal "Main Gate Android", data.dig("device", "name")
      assert_equal "paired", @invitation.reload.status
      refute_includes response.body, @invitation.phone
    end

    test "same idempotency retry returns safe state without another session or token" do
      headers = { "Idempotency-Key" => @idempotency_key }
      post "/scanner/pair", params: @payload, headers:, as: :json
      assert_response :created

      assert_no_difference -> { ScannerSession.count } do
        post "/scanner/pair", params: @payload, headers:, as: :json
      end

      assert_response :ok
      data = response.parsed_body.fetch("data")
      assert_equal true, data.fetch("replayed")
      assert_nil data["scanner_session_token"]
    end

    test "scanner sync accepts only the paired scanner bearer without a user JWT" do
      post "/scanner/pair",
           params: @payload,
           headers: { "Idempotency-Key" => @idempotency_key },
           as: :json
      assert_response :created
      scanner_token = response.parsed_body.dig("data", "scanner_session_token")

      get "/scanner/events/#{@event.id}/sync?mode=full",
          headers: { "Authorization" => "Bearer #{scanner_token}" },
          as: :json

      assert_response :ok
    end

    test "legacy user JWT and scanner header alone cannot authenticate scanner endpoints" do
      user_jwt = Core::TokenService.issue(Core::TokenService.access_token_payload(@creator))
      get "/scanner/events/#{@event.id}/sync?mode=full",
          headers: {
            "Authorization" => "Bearer #{user_jwt}",
            "X-Scanner-Token" => SecureRandom.hex(32)
          },
          as: :json

      assert_response :unauthorized
      assert_equal "authentication_failed", response.parsed_body.fetch("code")

      get "/scanner/events/#{@event.id}/sync?mode=full",
          headers: { "X-Scanner-Token" => SecureRandom.hex(32) },
          as: :json

      assert_response :unauthorized
      assert_equal "token_required", response.parsed_body.fetch("code")
    end

    test "requires idempotency key and rejects invalid capabilities without user JWT" do
      post "/scanner/pair", params: @payload, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")

      post "/scanner/pair",
           params: @payload.merge(pairing_token: "0" * 64),
           headers: { "Idempotency-Key" => "invalid-scanner-capability" },
           as: :json

      assert_response :unauthorized
      assert_equal "pairing_invalid", response.parsed_body.fetch("code")
    end

    private

    def create_invitation
      result = Scanners::CreateInvitation.call(
        event: @event,
        actor: @creator,
        phone: "0911 23 45 77",
        starts_at: 1.hour.ago,
        ends_at: 3.days.from_now,
        expires_at: 2.days.from_now,
        idempotency_key: "scanner-pair-invite-#{SecureRandom.hex(5)}"
      )
      raise result.error unless result.success?

      result.value.record
    end
  end
end
