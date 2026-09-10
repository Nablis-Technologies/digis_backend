# frozen_string_literal: true

require "test_helper"

module Admin
  module Commercial
    class SimulationsTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include CommercialIntegrationHelpers

      test "simulation creation requires an Idempotency-Key" do
        schedule = build_commercial_schedule(code: "simulation_terms")
        version, = build_commercial_version(schedule)

        post "/admin/commercial/simulations",
             params: { simulation: { fee_schedule_version_id: version.id,
                                      scenario: { resolution_context: { currency: "ETB" } } } },
             headers: admin_headers, as: :json

        assert_response :bad_request
        assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
      end

      test "simulation creation accepts a nested JSON scenario" do
        schedule = build_commercial_schedule(code: "simulation_json")
        version, = build_commercial_version(schedule)
        version.fee_components.create!(
          component_type: "platform_commission",
          calculation_type: "percentage",
          charged_to: "organizer",
          funded_by: "organizer",
          basis_type: "eligible_order_subtotal",
          rate_bps: 750,
          refund_policy: "nonrefundable",
          label: "Platform commission"
        )
        version.fee_components.create!(
          component_type: "processing_cost_recovery",
          calculation_type: "explicit_zero",
          charged_to: "buyer",
          funded_by: "buyer",
          refund_policy: "nonrefundable",
          label: "Processing cost recovery"
        )
        version.update!(definition_digest: ::Commercial::Definitions::Canonicalize.call(version:).value.digest)

        post "/admin/commercial/simulations",
             params: {
               simulation: {
                 fee_schedule_version_id: version.id,
                 scenario: {
                   resolution_context: {
                     organization_id: organizations_organizations(:one).id,
                     currency: "ETB",
                     settlement_currency: "ETB",
                     sale_context: "primary",
                     sales_channel: "online",
                     quoted_at: "2026-09-10T16:40:00Z",
                     eligible_order_subtotal_minor: 1_000,
                     item_face_value_minor: 1_000
                   }
                 }
               }
             },
             headers: admin_headers.merge("Idempotency-Key" => "simulation-json-1"), as: :json

        assert_response :created
        assert JSON.parse(response.body).dig("data", "passed")
      end
    end
  end
end
