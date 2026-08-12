# frozen_string_literal: true

require "test_helper"

module Admin
  module Commercial
    class ProgramsTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers
      include CommercialIntegrationHelpers

      test "admin can create a program backed by a program schedule" do
        schedule = build_commercial_schedule(schedule_type: "program", code: "launch_program")

        post "/admin/commercial/programs",
             params: { program: { fee_schedule_id: schedule.id, program_type: "charity",
                                   enrollment_mode: "manual", active: false } },
             headers: admin_headers.merge("Idempotency-Key" => "program-create-1"), as: :json

        assert_response :created
        assert_equal schedule.id, JSON.parse(response.body).dig("data", "fee_schedule_id")
      end

      test "program writes reject a missing Idempotency-Key" do
        post "/admin/commercial/programs",
             params: { program: { fee_schedule_id: SecureRandom.uuid, program_type: "charity" } },
             headers: admin_headers, as: :json

        assert_response :bad_request
        assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
      end
    end
  end
end
