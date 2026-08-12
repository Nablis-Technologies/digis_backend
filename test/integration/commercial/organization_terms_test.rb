# frozen_string_literal: true

require "test_helper"

module Commercial
  class OrganizationTermsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include CommercialIntegrationHelpers

    test "an organizer sees safe terms but no internal economics" do
      organization = organizations_organizations(:two)
      schedule = build_commercial_schedule(schedule_type: "platform_default", code: "terms_default")
      version, = build_commercial_version(schedule, status: "active")

      get "/commercial/organizations/#{organization.id}/terms", headers: owner_headers, as: :json

      assert_response :success
      data = JSON.parse(response.body).fetch("data")
      assert_equal organization.id, data.fetch("organization_id")
      refute data.to_s.match?(/risk_level|provider|margin|subsidy_budget|approval_discussion/)
      assert_equal version.id, data.dig("current_terms", "id")
    end

    test "a user outside the organization cannot read its terms" do
      get "/commercial/organizations/#{organizations_organizations(:two).id}/terms",
          headers: user_headers, as: :json

      assert_response :forbidden
    end
  end
end
