# frozen_string_literal: true

require "test_helper"

module Admin
  module Marketing
    class PlacementCapacityPoliciesTest < ActionDispatch::IntegrationTest
      include Core::AuthTestHelpers

      test "platform admins can list show create activate and retire capacity policies" do
        attributes = capacity_attributes(version: 777)
        post "/admin/marketing/placement_capacity_policies",
          params: { placement_capacity_policy: attributes, reason: "Set preview capacity" }.to_json,
          headers: admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-capacity-create")

        assert_response :created
        data = JSON.parse(response.body).fetch("data")
        policy_id = data.fetch("id")
        assert_equal 1, data.fetch("version")
        assert_equal "draft", data.fetch("status")
        assert_equal 6, data.fetch("max_concurrent")
        refute data.key?("idempotency_key_digest")
        refute data.key?("request_digest")

        get "/admin/marketing/placement_capacity_policies?q[status_eq]=draft&page=1&per_page=10", headers: admin_headers
        assert_response :success
        assert_includes JSON.parse(response.body).fetch("data").map { |policy| policy.fetch("id") }, policy_id

        get "/admin/marketing/placement_capacity_policies/#{policy_id}", headers: admin_headers
        assert_response :success
        assert_equal policy_id, JSON.parse(response.body).dig("data", "id")

        post "/admin/marketing/placement_capacity_policies/#{policy_id}/activate",
          params: { reason: "Activate preview capacity" }.to_json,
          headers: admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-capacity-activate")
        assert_response :success
        assert_equal "active", JSON.parse(response.body).dig("data", "status")

        post "/admin/marketing/placement_capacity_policies/#{policy_id}/retire",
          params: { reason: "Retire preview capacity" }.to_json,
          headers: admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-capacity-retire")
        assert_response :success
        assert_equal "retired", JSON.parse(response.body).dig("data", "status")
      end

      test "requires idempotency keys and replays capacity creation without duplicate versions" do
        post "/admin/marketing/placement_capacity_policies",
          params: { placement_capacity_policy: capacity_attributes, reason: "Create once" }.to_json,
          headers: admin_headers.merge("Content-Type" => "application/json")
        assert_response :bad_request
        assert_equal "missing_idempotency_key", JSON.parse(response.body).fetch("code")

        attributes = capacity_attributes
        headers = admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-capacity-replay")
        body = { placement_capacity_policy: attributes, reason: "Create once" }.to_json
        post "/admin/marketing/placement_capacity_policies", params: body, headers: headers
        assert_response :created
        first_id = JSON.parse(response.body).dig("data", "id")

        post "/admin/marketing/placement_capacity_policies", params: body, headers: headers
        assert_response :created
        assert_equal first_id, JSON.parse(response.body).dig("data", "id")
        assert_equal 1, ::Marketing::PlacementCapacityPolicy.where(surface: attributes.fetch(:surface)).count
      end

      test "rejects changed capacity under a reused idempotency key" do
        attributes = capacity_attributes
        headers = admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-capacity-conflict")
        post "/admin/marketing/placement_capacity_policies",
          params: { placement_capacity_policy: attributes, reason: "Create once" }.to_json, headers: headers
        assert_response :created

        post "/admin/marketing/placement_capacity_policies",
          params: { placement_capacity_policy: attributes.merge(max_concurrent: 7), reason: "Create once" }.to_json,
          headers: headers
        assert_response :conflict
        assert_equal "idempotency_conflict", JSON.parse(response.body).fetch("code")
      end

      test "attendees cannot access capacity administration and creation requires a reason" do
        get "/admin/marketing/placement_capacity_policies", headers: user_headers
        assert_response :forbidden

        post "/admin/marketing/placement_capacity_policies",
          params: { placement_capacity_policy: capacity_attributes }.to_json,
          headers: admin_headers.merge("Content-Type" => "application/json", "Idempotency-Key" => "admin-capacity-no-reason")
        assert_response :unprocessable_entity
        assert_equal "reason_required", JSON.parse(response.body).fetch("code")
      end

      private

      def capacity_attributes(**overrides)
        {
          surface: "public_discovery", max_concurrent: 6,
          effective_from: 1.hour.ago.iso8601, effective_until: 30.days.from_now.iso8601
        }.merge(overrides)
      end
    end
  end
end
