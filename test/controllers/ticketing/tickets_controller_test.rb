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
      %w[payment provider holder_name commercial_signature].each do |field|
        refute ticket.key?(field), "wallet response leaked #{field}"
      end
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
