# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationAnswersTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    setup do
      @answer = build_answer
    end

    test "respondent can revise an answer without receiving ciphertext" do
      post "/registration_answers/#{@answer.id}/revise",
           params: { source: "attendee_correction", value: "Corrected" },
           headers: user_headers.merge("Idempotency-Key" => "answer-revision-api-1"),
           as: :json

      assert_response :ok
      assert_equal 1, @answer.reload.revisions.count
      refute response.parsed_body.dig("data", "answer_ciphertext")
      refute response.parsed_body.dig("data", "answer")
    end

    test "answer revision without an idempotency key returns bad request" do
      post "/registration_answers/#{@answer.id}/revise",
           params: { source: "attendee_correction", value: "Corrected" },
           headers: user_headers,
           as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body["code"]
    end

    test "another user cannot revise an answer" do
      support_token = Core::TokenService.issue(
        Core::TokenService.access_token_payload(core_users(:support))
      )

      post "/registration_answers/#{@answer.id}/revise",
           params: { source: "attendee_correction", value: "Unauthorized" },
           headers: {
             "Authorization" => "Bearer #{support_token}",
             "Idempotency-Key" => "answer-revision-api-unauthorized"
           },
           as: :json

      assert_response :forbidden
      assert_equal "not_authorized", response.parsed_body["code"]
    end

    private

    def build_answer
      event = events_events(:ready_listing)
      actor = core_users(:super_admin)
      product = Catalog::Products::CreateDraft.call(
        event:,
        actor:,
        product_attributes: { name: "API answer ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value
      registration = Registration.create!(
        event:,
        ticket_type: product.ticket_type,
        user: core_users(:attendee),
        created_by: core_users(:attendee),
        source: "self_service",
        identity_digest: SecureRandom.hex(32),
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        submitted_at: Time.current
      )
      form = RegistrationForm.create!(event:, name: "API answer details", active: true)
      version = form.versions.create!(version: 1, status: "draft")
      question = version.questions.create!(
        key: "name",
        type: "short_text",
        response_scope: "registration",
        sensitivity: "standard",
        label: "Name",
        position: 0,
        options: [],
        validation_rules: {}
      )
      version.update!(status: "published", published_by: actor, published_at: Time.current)
      submission = registration.form_submissions.create!(
        registration_form_version: version,
        submitted_by_user: core_users(:attendee),
        submitted_at: Time.current
      )
      policy = Core::DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.minute.ago,
        created_by: actor
      )
      answered_at = Time.current
      submission.answers.create!(
        registration_question: question,
        question_key_snapshot: "name",
        question_type_snapshot: "short_text",
        response_scope_snapshot: "registration",
        question_label_snapshot: "Name",
        answer: "Original",
        retention_policy: policy,
        retain_until: answered_at + policy.retention_days.days,
        answered_at:
      )
    end
  end
end
