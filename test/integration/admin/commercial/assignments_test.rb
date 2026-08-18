# frozen_string_literal: true

require "test_helper"

module Admin
  module Commercial
    class AssignmentsTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include CommercialIntegrationHelpers

      setup do
        @schedule = build_commercial_schedule(code: "assignment_terms")
        @version, = build_commercial_version(@schedule)
      end

      test "admin can create an idempotent assignment draft" do
        params = { assignment: {
          organization_id: organizations_organizations(:two).id,
          fee_schedule_version_id: @version.id,
          assignment_type: "mutual_agreement",
          reason: "Negotiated launch terms",
          effective_from: 1.hour.ago.iso8601
        } }

        assert_difference -> { ::Commercial::Assignment.count }, 1 do
          post "/admin/commercial/assignments", params:,
               headers: admin_headers.merge("Idempotency-Key" => "assignment-create-1"), as: :json
          assert_response :created

          post "/admin/commercial/assignments", params:,
               headers: admin_headers.merge("Idempotency-Key" => "assignment-create-1"), as: :json
          assert_response :created
        end
      end

      test "assignment approval requires an Idempotency-Key" do
        assignment = ::Commercial::Assignment.create!(
          organization: organizations_organizations(:two), fee_schedule_version: @version,
          assignment_type: "mutual_agreement", status: "pending_approval",
          reason: "Existing evidence", effective_from: 1.hour.ago,
          risk_level: "high", created_by: core_users(:super_admin)
        )

        post "/admin/commercial/assignments/#{assignment.id}/approve",
             params: { reason: "Checker approval" }, headers: admin_headers, as: :json

        assert_response :bad_request
        assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
      end
    end
  end
end
