# frozen_string_literal: true

require "test_helper"

module Ticketing
  class PublicTicketViewsTest < ActionDispatch::IntegrationTest
    include Ticketing::PackageWorkflowTestHelpers

    setup do
      setup_package_workflow(admissions_per_unit: 1)
      @event.update!(status: "published", visibility: "public")
      @shadow = Core::User.create!(phone: "+251911000071")
      Ticketing::Ticket.where(id: @ticket.id).update_all(owner_user_id: @shadow.id)
      Ticketing::Registration.where(id: @registration.id).update_all(
        user_id: @shadow.id,
        created_by_id: @shadow.id
      )
      @codes = []
      @previous_sender = Rails.application.config.x.phone_verification_sender
      Rails.application.config.x.phone_verification_sender = lambda { |code:, **| @codes << code }
    end

    teardown do
      Rails.application.config.x.phone_verification_sender = @previous_sender
    end

    test "returns a no-store public ticket view with the active QR credential" do
      token = GuestTicketViewToken.issue(ticket: @ticket)

      get "/public/tickets/#{@ticket.id}", params: { view_token: token }

      assert_response :success
      assert_equal "no-store", response.headers.fetch("Cache-Control")
      data = response.parsed_body.fetch("data")
      assert_equal @ticket.id, data.fetch("id")
      assert data.fetch("credentials").first.fetch("qr_token").present?
      refute data.key?("owner_user_id")
      refute data.fetch("event").key?("organization_id")
    end

    test "rejects an un-tokenized public ticket request" do
      get "/public/tickets/#{@ticket.id}"

      assert_response :not_found
      assert_equal "invalid_guest_ticket_view", response.parsed_body.fetch("code")
    end

    test "rejects a signed view after the ticket credential generation changes" do
      token = GuestTicketViewToken.issue(ticket: @ticket)
      @ticket.current_credential_generation.update_columns(status: "revoked", revoked_at: Time.current)

      get "/public/tickets/#{@ticket.id}", params: { view_token: token }

      assert_response :not_found
      assert_equal "invalid_guest_ticket_view", response.parsed_body.fetch("code")
    end

    test "requests and verifies an OTP from the signed public ticket view" do
      token = GuestTicketViewToken.issue(ticket: @ticket)

      post "/public/ticket_views/#{token}/request_otp",
           params: { phone: @shadow.phone },
           headers: { "Idempotency-Key" => "public-ticket-otp-71" },
           as: :json

      assert_response :created
      challenge_id = response.parsed_body.dig("data", "challenge_id")
      assert challenge_id
      refute response.parsed_body.fetch("data").key?("code")

      post "/phone_verifications/#{challenge_id}/verify",
           params: { code: @codes.last },
           headers: { "Idempotency-Key" => "public-ticket-otp-verify-71" },
           as: :json

      assert_response :success
      assert response.parsed_body.dig("data", "verification_token").present?
    end

    test "claims the shadow registration and returns JWT tokens after OTP verification" do
      token = GuestTicketViewToken.issue(ticket: @ticket)
      post "/public/ticket_views/#{token}/request_otp",
           params: { phone: @shadow.phone },
           headers: { "Idempotency-Key" => "public-ticket-otp-claim-71" },
           as: :json
      challenge_id = response.parsed_body.dig("data", "challenge_id")

      post "/phone_verifications/#{challenge_id}/verify",
           params: { code: @codes.last },
           headers: { "Idempotency-Key" => "public-ticket-otp-claim-verify-71" },
           as: :json
      verification_token = response.parsed_body.dig("data", "verification_token")

      post "/registrations/#{@registration.id}/claim_guest",
           params: {
             phone: @shadow.phone,
             verification_token:,
             password: "password123",
             password_confirmation: "password123"
           },
           headers: { "Idempotency-Key" => "public-ticket-claim-71" },
           as: :json

      assert_response :success
      assert response.parsed_body.dig("data", "access_token").present?
      assert response.parsed_body.dig("data", "refresh_token").present?
      assert @shadow.reload.verified_at.present?

      get "/tickets", headers: {
        "Authorization" => "Bearer #{response.parsed_body.dig("data", "access_token")}"
      }

      assert_response :success
      assert_equal @ticket.id, response.parsed_body.fetch("data").first.fetch("id")

      post "/registrations/#{@registration.id}/claim_guest",
           params: {
             phone: @shadow.phone,
             verification_token:,
             password: "password123",
             password_confirmation: "password123"
           },
           headers: { "Idempotency-Key" => "public-ticket-claim-71" },
           as: :json

      assert_response :success
      assert response.parsed_body.dig("data", "access_token").present?
      assert_equal 1, Core::AuditLog.where(
        action: "ticketing.registration.guest_claimed", auditable_id: @registration.id
      ).count
    end
  end
end
