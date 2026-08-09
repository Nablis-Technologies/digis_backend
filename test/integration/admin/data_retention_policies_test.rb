# frozen_string_literal: true

require "test_helper"

module Admin
  class DataRetentionPoliciesTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @policy_params = {
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.hour.ago.iso8601
      }
    end

    test "core admin can create and list a retention policy" do
      assert_difference -> { Core::DataRetentionPolicy.count }, 1 do
        post admin_data_retention_policies_path,
             params: { data_retention_policy: @policy_params },
             headers: owner_headers, as: :json
      end
      assert_response :created
      assert_equal core_users(:core_admin).id, Core::DataRetentionPolicy.order(:created_at).last.created_by_id

      get admin_data_retention_policies_path, headers: owner_headers, as: :json
      assert_response :ok
      assert response.parsed_body.dig("data").present?
    end

    test "an organizer cannot create a platform retention policy" do
      post admin_data_retention_policies_path,
           params: { data_retention_policy: @policy_params },
           headers: headers_for(:support), as: :json

      assert_response :forbidden
    end

    test "only one active policy may exist for a category and jurisdiction" do
      post admin_data_retention_policies_path,
           params: { data_retention_policy: @policy_params },
           headers: admin_headers, as: :json
      assert_response :created

      duplicate = @policy_params.merge(version: 2, retention_days: 60)
      post admin_data_retention_policies_path,
           params: { data_retention_policy: duplicate },
           headers: admin_headers, as: :json

      assert_response :unprocessable_entity
    end

    test "core admin can place and release an idempotent event hold" do
      hold_params = {
        event_id: @event.id,
        category: "registration_free_text",
        reason_code: "legal_hold",
        starts_at: 1.hour.ago.iso8601,
        expires_at: 1.hour.from_now.iso8601
      }
      headers = owner_headers.merge("Idempotency-Key" => "retention-hold-1")

      assert_difference -> { Core::DataRetentionHold.count }, 1 do
        post admin_data_retention_holds_path,
             params: { data_retention_hold: hold_params }, headers:, as: :json
      end
      assert_response :created
      hold = Core::DataRetentionHold.order(:created_at).last

      assert_no_difference -> { Core::DataRetentionHold.count } do
        post admin_data_retention_holds_path,
             params: { data_retention_hold: hold_params }, headers:, as: :json
      end
      assert_response :created

      post release_admin_data_retention_hold_path(hold),
           headers: owner_headers.merge("Idempotency-Key" => "retention-release-1"), as: :json
      assert_response :ok
      assert_equal 1, Core::AuditLog
        .where(action: "retention.hold.released", auditable_type: "Core::DataRetentionHold", auditable_id: hold.id)
        .count
      assert hold.reload.released?

      post release_admin_data_retention_hold_path(hold),
           headers: owner_headers.merge("Idempotency-Key" => "retention-release-1"), as: :json
      assert_response :ok
      assert_equal 1, Core::AuditLog
        .where(action: "retention.hold.released", auditable_type: "Core::DataRetentionHold", auditable_id: hold.id)
        .count
    end

    test "hold placement is audited once across an idempotent replay" do
      hold_params = {
        event_id: @event.id,
        category: "registration_free_text",
        reason_code: "legal_hold",
        starts_at: 1.hour.ago.iso8601
      }
      headers = owner_headers.merge("Idempotency-Key" => "audited-retention-hold")

      post admin_data_retention_holds_path,
           params: { data_retention_hold: hold_params }, headers:, as: :json
      hold = Core::DataRetentionHold.order(:created_at).last
      post admin_data_retention_holds_path,
           params: { data_retention_hold: hold_params }, headers:, as: :json

      assert_response :created
      assert_equal 1, Core::AuditLog
        .where(action: "retention.hold.placed", auditable_type: "Core::DataRetentionHold", auditable_id: hold.id)
        .count
    end

    test "a release idempotency key cannot be reused for another hold" do
      first = create_hold("release-conflict-first")
      second = create_hold("release-conflict-second")
      headers = owner_headers.merge("Idempotency-Key" => "shared-release-key")

      post release_admin_data_retention_hold_path(first), headers:, as: :json
      assert_response :ok
      post release_admin_data_retention_hold_path(second), headers:, as: :json

      assert_response :unprocessable_entity
      assert_equal "idempotency_conflict", response.parsed_body["code"]
    end

    test "an organizer cannot place a retention hold" do
      post admin_data_retention_holds_path,
           params: { data_retention_hold: { event_id: @event.id, reason_code: "legal_hold" } },
           headers: headers_for(:support).merge("Idempotency-Key" => "organizer-hold"), as: :json

      assert_response :forbidden
    end

    test "hold release requires an idempotency key" do
      hold = Core::DataRetentionHold.create!(
        event: @event,
        reason_code: "legal_hold",
        placed_by: core_users(:super_admin),
        starts_at: 1.hour.ago,
        idempotency_key: "release-key-required"
      )

      post release_admin_data_retention_hold_path(hold), headers: owner_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body["code"]
    end

    test "hold creation requires an idempotency key" do
      post admin_data_retention_holds_path,
           params: { data_retention_hold: { event_id: @event.id, reason_code: "legal_hold" } },
           headers: owner_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body["code"]
    end

    test "a hold idempotency key cannot be reused with different attributes" do
      headers = owner_headers.merge("Idempotency-Key" => "retention-hold-conflict")
      first = {
        event_id: @event.id,
        category: "registration_free_text",
        reason_code: "legal_hold",
        starts_at: 1.hour.ago.iso8601
      }
      post admin_data_retention_holds_path,
           params: { data_retention_hold: first }, headers:, as: :json
      assert_response :created

      conflicting = first.merge(reason_code: "litigation")
      post admin_data_retention_holds_path,
           params: { data_retention_hold: conflicting }, headers:, as: :json

      assert_response :unprocessable_entity
      assert_equal "idempotency_conflict", response.parsed_body["code"]
    end

    test "hold creation enforces one scope and a valid window" do
      params = {
        event_id: @event.id,
        user_id: core_users(:attendee).id,
        reason_code: "legal_hold",
        starts_at: 1.hour.ago.iso8601,
        expires_at: 1.hour.from_now.iso8601
      }
      post admin_data_retention_holds_path,
           params: { data_retention_hold: params },
           headers: owner_headers.merge("Idempotency-Key" => "invalid-scope"), as: :json
      assert_response :unprocessable_entity

      invalid_window = params.except(:user_id).merge(expires_at: 2.hours.ago.iso8601)
      post admin_data_retention_holds_path,
           params: { data_retention_hold: invalid_window },
           headers: owner_headers.merge("Idempotency-Key" => "invalid-window"), as: :json
      assert_response :unprocessable_entity
    end

    private

    def headers_for(fixture_key)
      token = Core::TokenService.issue(
        Core::TokenService.access_token_payload(core_users(fixture_key))
      )
      { "Authorization" => "Bearer #{token}" }
    end

    def create_hold(key)
      Core::DataRetentionHold.create!(
        event: @event,
        category: "registration_free_text",
        reason_code: "legal_hold",
        placed_by: core_users(:super_admin),
        starts_at: 1.hour.ago,
        idempotency_key: key
      )
    end
  end
end
