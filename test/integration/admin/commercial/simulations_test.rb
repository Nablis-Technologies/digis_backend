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
    end
  end
end
