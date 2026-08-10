# frozen_string_literal: true

require "test_helper"

module Ticketing
  class AttendeeExportsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @user = core_users(:attendee)
      @session = Core::RefreshToken.generate(@user, ActionDispatch::TestRequest.create)
      @access_token = Core::TokenService.issue(
        Core::TokenService.access_token_payload(@user, jti: @session.jti)
      )
    end

    teardown do
      @session&.delete
      @admin_session&.delete
    end

    test "authenticated reauthentication verifies current_user password and returns a no-store proof" do
      post "/auth/reauthenticate",
           params: { password: "password123" },
           headers: auth_headers,
           as: :json

      assert_response :success
      assert_includes response.headers["Cache-Control"].to_s, "no-store"

      raw_proof = response.parsed_body.dig("data", "proof")
      assert raw_proof.present?

      proof = Core::ReauthenticationProof.where(user_id: @user.id).order(:issued_at).last
      assert_equal "attendee_export_request", proof.purpose
      assert_match(/\A[0-9a-f]{64}\z/, proof.session_jti_digest)
    end

    test "does not accept an identifier to authenticate another user" do
      other_user = core_users(:core_admin)
      other_user.update!(password: "other-password")

      post "/auth/reauthenticate",
           params: { identifier: other_user.phone, password: "other-password" },
           headers: auth_headers,
           as: :json

      assert_response :unauthorized
      assert_empty Core::ReauthenticationProof.where(user_id: @user.id)
      assert_empty Core::ReauthenticationProof.where(user_id: other_user.id)
    end

    test "returns one generic bad-password response and does not issue a proof" do
      post "/auth/reauthenticate",
           params: { password: "wrong-password" },
           headers: auth_headers,
           as: :json

      assert_response :unauthorized
      first_body = response.parsed_body

      post "/auth/reauthenticate",
           params: { password: "another-wrong-password" },
           headers: auth_headers,
           as: :json

      assert_response :unauthorized
      second_body = response.parsed_body
      assert_equal first_body["code"], second_body["code"]
      assert_equal first_body["error"], second_body["error"]
      assert_empty Core::ReauthenticationProof.where(user_id: @user.id)
    end

    test "requires a password before attempting reauthentication" do
      post "/auth/reauthenticate",
           params: {},
           headers: auth_headers,
           as: :json

      assert_response :bad_request
      assert_includes response.parsed_body["error"], "password"
      assert_empty Core::ReauthenticationProof.where(user_id: @user.id)
    end

    test "uses the memoized decoded access-token JTI when issuing a proof" do
      payload = Core::TokenService.access_token_payload(@user, jti: @session.jti)
      Core::TokenService.expects(:decode).once.with(@access_token, verify_revocation: true).returns(payload)

      post "/auth/reauthenticate",
           params: { password: "password123" },
           headers: auth_headers,
           as: :json

      assert_response :success
    end

    test "binds proofs to the current access-token JTI" do
      post "/auth/reauthenticate",
           params: { password: "password123" },
           headers: auth_headers,
           as: :json
      assert_response :success
      first_proof = Core::ReauthenticationProof.where(user_id: @user.id).sole

      second_session = Core::RefreshToken.generate(@user, ActionDispatch::TestRequest.create)
      second_token = Core::TokenService.issue(
        Core::TokenService.access_token_payload(@user, jti: second_session.jti)
      )
      post "/auth/reauthenticate",
           params: { password: "password123" },
           headers: { "Authorization" => "Bearer #{second_token}" },
           as: :json
      assert_response :success
      second_proof = Core::ReauthenticationProof.where(user_id: @user.id).where.not(id: first_proof.id).sole

      refute_equal first_proof.session_jti_digest, second_proof.session_jti_digest
    ensure
      second_session&.delete
    end

    test "requires an idempotency key before parsing a new export request" do
      post "/events/#{events_events(:ready_listing).id}/attendee_exports",
           params: export_params,
           headers: admin_headers,
           as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body["code"]
    end

    test "filters export selectors and filter objects from request logging" do
      configured = Rails.application.config.filter_parameters.map(&:to_s)

      assert configured.any? { |entry| entry.include?("field_keys") }
      assert configured.any? { |entry| entry.include?("filters") }
    end

    test "requests a private attendee export with one proof and replays without another proof" do
      proof = issue_admin_proof
      headers = @admin_export_headers.merge("Idempotency-Key" => "integration-export-key")

      assert_difference -> { Ticketing::AttendeeExport.count }, 1 do
        post "/events/#{events_events(:ready_listing).id}/attendee_exports",
             params: export_params.merge(proof:), headers:, as: :json
      end
      assert_response :created
      export_id = response.parsed_body.dig("data", "id")

      post "/events/#{events_events(:ready_listing).id}/attendee_exports",
           params: export_params, headers:, as: :json

      assert_response :created
      assert_equal export_id, response.parsed_body.dig("data", "id")
      assert_equal 1, Core::OutboxEvent.where(event_type: "ticketing.attendee_export.requested").count
    end

    test "rejects a different request under an existing idempotency key" do
      proof = issue_admin_proof
      headers = @admin_export_headers.merge("Idempotency-Key" => "integration-conflict-key")
      post "/events/#{events_events(:ready_listing).id}/attendee_exports",
           params: export_params.merge(proof:), headers:, as: :json
      assert_response :created

      post "/events/#{events_events(:ready_listing).id}/attendee_exports",
           params: export_params.merge(field_keys: [ "registration_status" ]), headers:, as: :json

      assert_response :conflict
      assert_equal "idempotency_conflict", response.parsed_body["code"]
    end

    private

    def issue_admin_proof
      admin = core_users(:super_admin)
      @admin_session ||= Core::RefreshToken.generate(admin, ActionDispatch::TestRequest.create)
      @admin_token ||= Core::TokenService.issue(
        Core::TokenService.access_token_payload(admin, jti: @admin_session.jti)
      )
      @admin_export_headers = { "Authorization" => "Bearer #{@admin_token}" }
      post "/auth/reauthenticate",
           params: { password: "password123" },
           headers: @admin_export_headers,
           as: :json
      assert_response :success
      response.parsed_body.dig("data", "proof")
    end

    def export_params
      {
        row_mode: "registration",
        field_keys: [ "registration_id" ],
        filters: {},
        reason_code: "event_operations"
      }
    end

    def auth_headers
      { "Authorization" => "Bearer #{@access_token}" }
    end
  end
end
