# frozen_string_literal: true

require "test_helper"

module Admin
  module Commercial
    class SubsidyBudgetsTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include CommercialIntegrationHelpers

      test "budget inspection does not expose write access to a view-only admin" do
        get "/admin/commercial/subsidy_budgets", headers: owner_headers, as: :json
        assert_response :forbidden
      end

      test "budget creation requires an Idempotency-Key" do
        post "/admin/commercial/subsidy_budgets",
             params: { subsidy_budget: { currency: "ETB", limit_minor: 1000 } },
             headers: admin_headers, as: :json

        assert_response :bad_request
        assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
      end
    end
  end
end
