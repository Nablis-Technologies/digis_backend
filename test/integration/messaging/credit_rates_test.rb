# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class CreditRatesTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @organization = Organizations::Organization.create!(
        name: "Rate API #{SecureRandom.hex(6)}", slug: "rate-api-#{SecureRandom.hex(6)}",
        organizer_type: "company", category: "conference"
      )
      @owner = Core::User.create!(
        email: "rate-owner-#{SecureRandom.hex(4)}@example.test",
        phone: "+2519#{rand(10_000_000..99_999_999)}", verified_at: Time.current,
        password: "password123"
      )
      Organizations::Membership.create!(user: @owner, organization: @organization, role: "owner", status: "active")
      @rate = CreditRateVersion.create!(
        organization: @organization, channel: "sms", version: 1, currency: "ETB", unit_price_minor: 10,
        effective_from: 1.hour.ago, status: "active", volume_tiers: [],
        idempotency_key_digest: Digest::SHA256.hexdigest("owner-rate"),
        request_digest: Digest::SHA256.hexdigest("owner-rate-request"), activated_at: 1.hour.ago
      )
      @owner_token = Core::TokenService.issue(Core::TokenService.access_token_payload(@owner))
    end

    test "allows an organization owner to read its applicable rates" do
      get "/organizations/#{@organization.id}/messaging/credit_rates",
        headers: { "Authorization" => "Bearer #{@owner_token}" }, as: :json

      assert_response :success
      assert_equal [ @rate.id ], JSON.parse(response.body).fetch("data").map { |row| row.fetch("id") }
    end

    test "denies an unrelated attendee from reading organizer rates" do
      get "/organizations/#{@organization.id}/messaging/credit_rates", headers: user_headers, as: :json

      assert_response :forbidden
    end
  end
end
