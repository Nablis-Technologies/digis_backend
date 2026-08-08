# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Forms
    class PersistSubmissionTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        product = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @actor,
          product_attributes: { name: "Persist ticket", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1
          },
          inventory_configuration: { mode: "unlimited" }
        ).value
        @registration = Registration.create!(
          event: @event,
          ticket_type: product.ticket_type,
          user: core_users(:attendee),
          created_by: core_users(:attendee),
          source: "self_service",
          identity_digest: "d" * 64,
          package_quantity: 1,
          admissions_per_unit_snapshot: 1,
          party_size: 1,
          status: "pending_payment",
          submitted_at: Time.current
        )
        form = RegistrationForm.create!(event: @event, name: "Persist details", active: true)
        @version = form.versions.create!(
          version: 1, status: "draft"
        )
        @question = @version.questions.create!(
          key: "name",
          type: "short_text",
          response_scope: "registration",
          sensitivity: "standard",
          label: "Name",
          position: 0,
          options: [],
          validation_rules: {}
        )
        @version.update!(status: "published", published_by: @actor, published_at: Time.current)
        @policy = Core::DataRetentionPolicy.create!(
          category: "registration_free_text",
          version: 1,
          retention_days: 30,
          action: "erase_payload",
          status: "active",
          effective_at: 1.minute.ago,
          created_by: @actor
        )
      end

      test "persists snapshots and the active retention policy for normalized answers" do
        result = PersistSubmission.call(
          registration: @registration,
          schema: [ @version ],
          submission: {
            answers: [ { question_key: "name", value: "Ada" } ]
          },
          actor: core_users(:attendee)
        )

        assert_predicate result, :success?
        persisted = @registration.reload.form_submissions.first.answers.first
        assert_equal @question.id, persisted.registration_question_id
        assert_equal @policy.id, persisted.retention_policy_id
        assert_equal "Ada", persisted.answer
        assert_equal persisted.answered_at + 30.days, persisted.retain_until
      end

      test "does not write a submission when no active policy exists" do
        @version.registration_form.update!(active: false)
        form = RegistrationForm.create!(event: @event, name: "Structured details", active: true)
        version = form.versions.create!(version: 1, status: "draft")
        question = version.questions.create!(
          key: "meal",
          type: "single_choice",
          response_scope: "registration",
          sensitivity: "standard",
          label: "Meal",
          position: 0,
          options: [ { "key" => "standard", "label" => "Standard" } ],
          validation_rules: {}
        )
        version.update!(status: "published", published_by: @actor, published_at: Time.current)

        result = PersistSubmission.call(
          registration: @registration,
          schema: [ version ],
          submission: {
            answers: [ { question_key: question.key, value: "standard" } ]
          },
          actor: core_users(:attendee)
        )

        assert_predicate result, :failure?
        assert_equal "retention_policy_not_found", result.error.code
        assert_empty @registration.reload.form_submissions
      end

      test "rejects a version retired after schema selection without writing" do
        @version.update!(status: "retired")

        result = PersistSubmission.call(
          registration: @registration,
          schema: [ @version ],
          submission: { answers: [ { question_key: "name", value: "Ada" } ] },
          actor: core_users(:attendee)
        )

        assert_predicate result, :failure?
        assert_equal "stale_form_version", result.error.code
        assert_empty @registration.reload.form_submissions
      end

      test "rejects a schema that omits a newly published active form" do
        new_form = RegistrationForm.create!(event: @event, name: "New details", active: true)
        new_version = new_form.versions.create!(version: 1, status: "draft")
        new_version.questions.create!(
          key: "new_name",
          type: "short_text",
          response_scope: "registration",
          sensitivity: "standard",
          label: "New name",
          required: true,
          position: 0,
          options: [],
          validation_rules: {}
        )
        new_version.update!(status: "published", published_by: @actor, published_at: Time.current)

        result = PersistSubmission.call(
          registration: @registration,
          schema: [ @version ],
          submission: { answers: [ { question_key: "name", value: "Ada" } ] },
          actor: core_users(:attendee)
        )

        assert_predicate result, :failure?
        assert_equal "stale_form_version", result.error.code
        assert_empty @registration.reload.form_submissions
      end

      test "rejects an empty schema when a current form exists" do
        result = PersistSubmission.call(
          registration: @registration,
          schema: [],
          submission: { answers: [] },
          actor: core_users(:attendee)
        )

        assert_predicate result, :failure?
        assert_equal "stale_form_version", result.error.code
        assert_empty @registration.reload.form_submissions
      end

      test "returns a typed failure for nil submission input" do
        result = PersistSubmission.call(
          registration: @registration,
          schema: [ @version ],
          submission: nil,
          actor: core_users(:attendee)
        )

        assert_predicate result, :failure?
        assert_equal "invalid_submission", result.error.code
        assert_empty @registration.reload.form_submissions
      end
    end
  end
end
