# frozen_string_literal: true

require "test_helper"

module Admin
  module Commercial
    class FeeSchedulesTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers

      test "platform admins can create a fee schedule and replay the request" do
        payload = { fee_schedule: { name: "Platform terms", code: "platform_terms", schedule_type: "custom" } }

        assert_difference -> { ::Commercial::FeeSchedule.count }, 1 do
          post "/admin/commercial/fee_schedules", params: payload,
               headers: admin_headers.merge("Idempotency-Key" => "fee-schedule-create-1"), as: :json
          assert_response :created

          post "/admin/commercial/fee_schedules", params: payload,
               headers: admin_headers.merge("Idempotency-Key" => "fee-schedule-create-1"), as: :json
          assert_response :created
        end
      end

      test "fee schedule mutations require an Idempotency-Key" do
        post "/admin/commercial/fee_schedules",
             params: { fee_schedule: { name: "Missing key", code: "missing_key", schedule_type: "custom" } },
             headers: admin_headers, as: :json

        assert_response :bad_request
        assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
      end

      test "a delegated admin with only commercial view can inspect but not draft" do
        get "/admin/commercial/fee_schedules", headers: owner_headers, as: :json
        assert_response :success

        post "/admin/commercial/fee_schedules",
             params: { fee_schedule: { name: "Forbidden", code: "forbidden", schedule_type: "custom" } },
             headers: owner_headers.merge("Idempotency-Key" => "fee-schedule-forbidden"), as: :json
        assert_response :forbidden
      end
    end
  end
end
