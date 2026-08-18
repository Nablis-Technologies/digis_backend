# frozen_string_literal: true

require "test_helper"

module Admin
  module Commercial
    class FeeScheduleVersionsTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include CommercialIntegrationHelpers

      setup do
        @schedule = build_commercial_schedule(code: "version_terms")
      end

      test "admin can create a version with an allowlisted component and inspect it" do
        post "/admin/commercial/fee_schedules/#{@schedule.id}/fee_schedule_versions",
             params: {
               fee_schedule_version: {
                 acceptance_policy: "none",
                 components: [
                   { component_type: "buyer_service_fee", calculation_type: "percentage",
                     charged_to: "buyer", funded_by: "buyer", basis_type: "item_face_value",
                     rate_bps: 250, refund_policy: "nonrefundable", label: "Buyer service fee" }
                 ]
               }
             },
             headers: admin_headers.merge("Idempotency-Key" => "version-create-1"), as: :json

        assert_response :created
        version_id = JSON.parse(response.body).dig("data", "id")
        assert version_id

        get "/admin/commercial/fee_schedule_versions/#{version_id}", headers: admin_headers, as: :json
        assert_response :success
        assert JSON.parse(response.body).dig("data", "fee_components").present?
      end

      test "version lifecycle mutations reject a missing Idempotency-Key" do
        version, = build_commercial_version(@schedule)

        post "/admin/commercial/fee_schedule_versions/#{version.id}/simulate",
             params: { scenario: { resolution_context: { currency: "ETB" } } },
             headers: admin_headers, as: :json

        assert_response :bad_request
        assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
      end
    end
  end
end
