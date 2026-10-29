# frozen_string_literal: true

require "test_helper"

module Admin
  module Marketing
    class PlacementOffersTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers

      test "platform admins can list show create activate and retire offer versions" do
        headers = admin_headers.merge("Idempotency-Key" => "admin-offer-create-#{SecureRandom.uuid}")
        post "/admin/marketing/placement_offers", params: { placement_offer: offer_attributes(version: 999),
          reason: "Launch a preview offer" }.to_json,
          headers: headers.merge("Content-Type" => "application/json")

        assert_response :created
        data = JSON.parse(response.body).fetch("data")
        offer_id = data.fetch("id")
        assert_equal 1, data.fetch("version")
        assert_equal "draft", data.fetch("status")
        assert_equal 50_000, data.fetch("daily_rate_minor")
        refute data.key?("idempotency_key_digest")
        refute data.key?("request_digest")

        get "/admin/marketing/placement_offers", headers: admin_headers
        assert_response :success
        assert_includes JSON.parse(response.body).fetch("data").map { |offer| offer.fetch("id") }, offer_id

        get "/admin/marketing/placement_offers/#{offer_id}", headers: admin_headers
        assert_response :success
        assert_equal offer_id, JSON.parse(response.body).dig("data", "id")

        post "/admin/marketing/placement_offers/#{offer_id}/activate",
          params: { reason: "Start preview sales" }.to_json,
          headers: admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-offer-activate")
        assert_response :success
        assert_equal "active", JSON.parse(response.body).dig("data", "status")

        post "/admin/marketing/placement_offers/#{offer_id}/retire",
          params: { reason: "Pause preview sales" }.to_json,
          headers: admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-offer-retire")
        assert_response :success
        assert_equal "retired", JSON.parse(response.body).dig("data", "status")
      end

      test "requires idempotency keys and replays create without duplicate versions" do
        post "/admin/marketing/placement_offers",
          params: { placement_offer: offer_attributes, reason: "Create once" }.to_json,
          headers: admin_headers.merge("Content-Type" => "application/json")
        assert_response :bad_request
        assert_equal "missing_idempotency_key", JSON.parse(response.body).fetch("code")

        headers = admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-offer-replay")
        attributes = offer_attributes
        request_body = { placement_offer: attributes, reason: "Create once" }.to_json
        post "/admin/marketing/placement_offers", params: request_body, headers: headers
        assert_response :created
        first_id = JSON.parse(response.body).dig("data", "id")

        post "/admin/marketing/placement_offers", params: request_body, headers: headers
        assert_response :created
        assert_equal first_id, JSON.parse(response.body).dig("data", "id")
        assert_equal 1, ::Marketing::PlacementOffer.where(code: attributes.fetch(:code)).count
      end

      test "rejects changed request content under a reused idempotency key" do
        headers = admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-offer-conflict")
        attributes = offer_attributes
        post "/admin/marketing/placement_offers",
          params: { placement_offer: attributes, reason: "Create first" }.to_json, headers: headers
        assert_response :created

        post "/admin/marketing/placement_offers",
          params: { placement_offer: attributes.merge(daily_rate_minor: 60_000), reason: "Create first" }.to_json,
          headers: headers
        assert_response :conflict
        assert_equal "idempotency_conflict", JSON.parse(response.body).fetch("code")
      end

      test "attendees cannot access offer administration" do
        get "/admin/marketing/placement_offers", headers: user_headers

        assert_response :forbidden
      end

      test "requires a human reason for administrative offer creation" do
        post "/admin/marketing/placement_offers",
          params: { placement_offer: offer_attributes }.to_json,
          headers: admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-offer-no-reason")

        assert_response :unprocessable_entity
        assert_equal "reason_required", JSON.parse(response.body).fetch("code")
      end

      private

      def offer_attributes(**overrides)
        {
          code: "admin_offer_#{SecureRandom.hex(4)}", surface: "public_discovery", daily_rate_minor: 50_000,
          currency: "ETB", minimum_duration_seconds: 24.hours.to_i, maximum_duration_seconds: 14.days.to_i,
          terms_version: "admin-v1", starts_at: 1.day.ago.iso8601, ends_at: 30.days.from_now.iso8601
        }.merge(overrides)
      end
    end
  end
end
