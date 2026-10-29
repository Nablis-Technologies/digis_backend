# frozen_string_literal: true

require "digest"
require "test_helper"

module Messaging
  class CreditTopUpsTest < ActionDispatch::IntegrationTest
    class FakeAdapter < Payments::Providers::Adapter
      def create(**) = Payments::Providers::Result.unknown(provider_reference: "api-ref", checkout_url: "https://checkout.test/api")
      def cancel(**) = Payments::Providers::Result.cancelled
      def verify(**) = Payments::Providers::Result.unknown
      def refund(**) = Payments::Providers::Result.unknown
      def verify_refund(**) = Payments::Providers::Result.unknown
      def available_balance(**) = { amount_minor: 100_000, currency: "ETB" }
      def capabilities = { currencies: [ "ETB" ], payment_methods: [ "telebirr" ] }
      def settlement_grace_minutes = 5
    end

    include Core::AuthTestHelpers

    setup do
      @organization = organizations_organizations(:one)
      @rate = CreditRateVersion.create!(
        channel: "sms", version: 1, currency: "ETB", unit_price_minor: 10,
        effective_from: 1.hour.ago, status: "active", volume_tiers: [],
        idempotency_key_digest: Digest::SHA256.hexdigest("api-rate"),
        request_digest: Digest::SHA256.hexdigest("api-rate-request"), activated_at: 1.hour.ago
      )
      Payments::Providers::Registry.register("chapa", FakeAdapter.new)
    end

    teardown { Payments::Providers::Registry.instance_variable_set(:@adapters, {}) }

    test "estimates, creates, and reads a credit top-up" do
      get "/organizations/#{@organization.id}/messaging/credit_rates", headers: admin_headers, as: :json
      assert_response :success
      rate_data = JSON.parse(response.body).fetch("data").first
      assert_equal [ @rate.id ], [ rate_data.fetch("id") ]
      refute rate_data.key?("provider_cost_minor")

      post "/organizations/#{@organization.id}/messaging/credit_estimates",
        params: { credit_estimate: { channel: "sms", quantity: 10, currency: "ETB" } }.to_json,
        headers: admin_headers.merge("Content-Type" => "application/json")
      assert_response :success
      assert_equal 100, JSON.parse(response.body).dig("data", "amount_minor")

      post "/organizations/#{@organization.id}/messaging/credit_top_ups",
        params: { credit_top_up: { channel: "sms", quantity: 10, currency: "ETB" } }.to_json,
        headers: admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "api-top-up")
      assert_response :created
      data = JSON.parse(response.body).fetch("data")
      assert_equal "pending_payment", data.dig("top_up", "status")
      assert_equal "https://checkout.test/api", data.dig("payment", "checkout_url")

      get "/organizations/#{@organization.id}/messaging/credit_top_ups/#{data.dig('top_up', 'id')}",
        headers: admin_headers, as: :json
      assert_response :success
      assert_equal data.dig("top_up", "id"), JSON.parse(response.body).dig("data", "id")
    end

    test "requires an idempotency key for top-up creation" do
      post "/organizations/#{@organization.id}/messaging/credit_top_ups",
        params: { credit_top_up: { channel: "sms", quantity: 10, currency: "ETB" } }.to_json,
        headers: admin_headers.merge("Content-Type" => "application/json")

      assert_response :bad_request
      assert_equal "missing_idempotency_key", JSON.parse(response.body).fetch("code")
    end
  end
end
