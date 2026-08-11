# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Ticketing::ConsentTestHelpers

    setup do
      @event = events_events(:ready_listing)
      @ticket_type = create_ticket_type
      create_required_form
      Core::DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.minute.ago,
        created_by: core_users(:super_admin)
      )
    end

    test "an authenticated attendee submits their registration and receives a privacy-safe action" do
      @ticket_type.event_product.prices.create!(
        type: "base", currency: "ETB", amount_minor: 0, active_from: 1.minute.ago
      )

      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params,
           headers: submission_headers,
           as: :json

      assert_response :created
      data = response.parsed_body.fetch("data")
      assert_equal "requires_confirmation", data.dig("next_action", "type")
      assert_equal "pending_payment", data.dig("registration", "status")
      assert_not data.fetch("registration").key?("identity_digest")
    end

    test "registration submission snapshots and accepts supplied buyer consent" do
      _document, version = create_consent_document(scope: "buyer", name: "API registration terms")
      Core::DataRetentionPolicy.create!(
        category: "consent_evidence",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.minute.ago,
        created_by: core_users(:super_admin)
      )

      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params.merge(
             consents: [
               {
                  consent_document_version_id: version.id,
                  request_uuid: SecureRandom.uuid,
                  idempotency_key: "registration-consent-accept-1",
                  acceptance_method: "otp",
                 content_sha256: version.content_sha256
               }
             ]
           ),
           headers: submission_headers("registration-consent-1"),
           as: :json

      assert_response :created
      registration = Registration.find(response.parsed_body.dig("data", "registration", "id"))
      assert_equal "accepted", registration.consent_requirements.first.status
      assert_not response.parsed_body.fetch("data").key?("evidence_digest")
    end

    test "registration submission without an idempotency key returns bad request" do
      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params,
           headers: user_headers,
           as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body["code"]
    end

    test "replaying a registration submission with the same idempotency key is a no-op" do
      headers = submission_headers("registration-replay-1")

      post "/ticket_types/#{@ticket_type.id}/registrations", params: registration_params, headers:, as: :json
      assert_response :created
      registration_id = response.parsed_body.dig("data", "registration", "id")

      post "/ticket_types/#{@ticket_type.id}/registrations", params: registration_params, headers:, as: :json

      assert_response :success
      assert_equal registration_id, response.parsed_body.dig("data", "registration", "id")
      assert_equal 1, Registration.count
      assert_equal 1, RegistrationFormSubmission.count
    end

    test "an identical submission with a fresh idempotency key returns the existing active registration" do
      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params,
           headers: submission_headers("registration-fresh-key-1"),
           as: :json
      assert_response :created
      registration_id = response.parsed_body.dig("data", "registration", "id")

      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params,
           headers: submission_headers("registration-fresh-key-2"),
           as: :json

      assert_response :success
      assert_equal registration_id, response.parsed_body.dig("data", "registration", "id")
      assert_equal 1, Registration.count
      assert_equal 1, RegistrationFormSubmission.count
    end

    test "rejects a changed registration request under the same idempotency key" do
      headers = submission_headers("registration-conflict-1")

      post "/ticket_types/#{@ticket_type.id}/registrations", params: registration_params, headers:, as: :json
      assert_response :created

      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params.merge(package_quantity: 2),
           headers:,
           as: :json

      assert_response :unprocessable_entity
      assert_equal "idempotency_conflict", response.parsed_body["code"]
      assert_equal 1, Registration.count
    end

    test "rejects changed form answers under the same idempotency key" do
      headers = submission_headers("registration-answer-conflict-1")

      post "/ticket_types/#{@ticket_type.id}/registrations", params: registration_params, headers:, as: :json
      assert_response :created

      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params.merge(answers: [ { question_key: "name", value: "Grace" } ]),
           headers:,
           as: :json

      assert_response :unprocessable_entity
      assert_equal "idempotency_conflict", response.parsed_body["code"]
    end

    test "rejects changed audience proof under the same idempotency key" do
      headers = submission_headers("registration-audience-conflict-1")

      post "/ticket_types/#{@ticket_type.id}/registrations", params: registration_params, headers:, as: :json
      assert_response :created

      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params.merge(access_code: "different-proof"),
           headers:,
           as: :json

      assert_response :unprocessable_entity
      assert_equal "idempotency_conflict", response.parsed_body["code"]
    end

    test "rejects changed form answers under a new idempotency key for an active registration" do
      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params,
           headers: submission_headers("registration-active-answer-1"),
           as: :json
      assert_response :created

      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params.merge(answers: [ { question_key: "name", value: "Grace" } ]),
           headers: submission_headers("registration-active-answer-2"),
           as: :json

      assert_response :unprocessable_entity
      assert_equal "active_registration_conflict", response.parsed_body["code"]
    end

    test "rejects changed audience proof under a new idempotency key for an active registration" do
      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params,
           headers: submission_headers("registration-active-proof-1"),
           as: :json
      assert_response :created

      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params.merge(access_code: "different-proof"),
           headers: submission_headers("registration-active-proof-2"),
           as: :json

      assert_response :unprocessable_entity
      assert_equal "active_registration_conflict", response.parsed_body["code"]
    end

    test "rejects scalar answers input as an invalid submission" do
      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params.merge(answers: "not-an-array"),
           headers: submission_headers("registration-malformed-scalar"),
           as: :json

      assert_response :unprocessable_entity
      assert_equal "invalid_submission", response.parsed_body["code"]
    end

    test "rejects malformed entries in answers input as an invalid submission" do
      post "/ticket_types/#{@ticket_type.id}/registrations",
           params: registration_params.merge(answers: [ { question_key: "name", value: "Ada" }, "not-an-answer" ]),
           headers: submission_headers("registration-malformed-entry"),
           as: :json

      assert_response :unprocessable_entity
      assert_equal "invalid_submission", response.parsed_body["code"]
    end

    test "registration submission requires authentication" do
      post "/ticket_types/#{@ticket_type.id}/registrations", params: registration_params, as: :json

      assert_response :unauthorized
    end

    test "an attendee cannot read another attendee registration" do
      registration = Registration.create!(
        event: @event,
        ticket_type: @ticket_type,
        user: core_users(:attendee),
        created_by: core_users(:attendee),
        source: "self_service",
        identity_digest: "a" * 64,
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        submitted_at: Time.current
      )
      support_token = Core::TokenService.issue(Core::TokenService.access_token_payload(core_users(:support)))

      get "/registrations/#{registration.id}", headers: { "Authorization" => "Bearer #{support_token}" }, as: :json

      assert_response :forbidden
    end

    test "a registrant can read their registration without private identity data" do
      registration = create_registration

      get "/registrations/#{registration.id}", headers: user_headers, as: :json

      assert_response :ok
      assert_equal registration.id, response.parsed_body.dig("data", "id")
      assert_not response.parsed_body.fetch("data").key?("identity_digest")
      assert_not response.parsed_body.fetch("data").key?("user_id")
    end

    test "an event organizer can read a registration without private identity data" do
      registration = create_registration

      get "/registrations/#{registration.id}", headers: owner_headers, as: :json

      assert_response :ok
      assert_equal registration.id, response.parsed_body.dig("data", "id")
      assert_not response.parsed_body.fetch("data").key?("identity_digest")
      assert_not response.parsed_body.fetch("data").key?("user_id")
    end

    private

    def registration_params
      {
        phone: core_users(:attendee).phone,
        package_quantity: 1,
        answers: [ { question_key: "name", value: "Ada" } ]
      }
    end

    def submission_headers(key = "registration-submit-1")
      user_headers.merge("Idempotency-Key" => key)
    end

    def create_registration
      Registration.create!(
        event: @event,
        ticket_type: @ticket_type,
        user: core_users(:attendee),
        created_by: core_users(:attendee),
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        next_action_snapshot: "requires_order",
        submitted_at: Time.current
      )
    end

    def create_ticket_type
      Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "API registration ticket #{SecureRandom.hex(4)}", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value.ticket_type
    end

    def create_required_form
      form = RegistrationForm.create!(event: @event, name: "API registration form #{SecureRandom.hex(4)}", active: true)
      version = form.versions.create!(version: 1, status: "draft")
      version.questions.create!(
        key: "name",
        type: "short_text",
        response_scope: "registration",
        sensitivity: "standard",
        label: "Name",
        required: true,
        position: 0,
        options: [],
        validation_rules: {}
      )
      version.update!(status: "published", published_by: core_users(:super_admin), published_at: Time.current)
    end
  end
end
