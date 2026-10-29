# frozen_string_literal: true

require "test_helper"

module Admin
  module Messaging
    class CreditRatesTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers

      test "platform admins can create and activate a draft rate" do
        post "/admin/messaging/credit_rates",
          params: {
            credit_rate_version: {
              channel: "sms", currency: "ETB", unit_price_minor: 12,
              effective_from: 1.hour.ago.iso8601
            }
          }.to_json,
          headers: admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-rate-create")
        assert_response :created
        id = JSON.parse(response.body).dig("data", "id")

        post "/admin/messaging/credit_rates/#{id}/activate",
          headers: admin_headers.merge("Idempotency-Key" => "admin-rate-activate"), as: :json
        assert_response :success
        assert_equal "active", JSON.parse(response.body).dig("data", "status")
      end

      test "credit adjustment requires an idempotency key" do
        organization = organizations_organizations(:one)
        ::Messaging::CreditAccount.create!(organization:, channel: "sms")

        post "/admin/organizations/#{organization.id}/messaging/credit_adjustments",
          params: { credit_adjustment: { channel: "sms", quantity: 10, reason: "test" } }.to_json,
          headers: admin_headers.merge("Content-Type" => "application/json")

        assert_response :bad_request
        assert_equal "missing_idempotency_key", JSON.parse(response.body).fetch("code")
      end

      test "platform admins can append a reasoned credit adjustment" do
        organization = organizations_organizations(:one)
        ::Messaging::CreditAccount.create!(organization:, channel: "sms")

        post "/admin/organizations/#{organization.id}/messaging/credit_adjustments",
          params: { credit_adjustment: { channel: "sms", quantity: 10, reason: "test grant" } }.to_json,
          headers: admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-adjust")

        assert_response :success
        assert_equal "adjustment", JSON.parse(response.body).dig("data", "entry_type")
      end
    end
  end
end
