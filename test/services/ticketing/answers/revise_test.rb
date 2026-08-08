# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Answers
    class ReviseTest < ActiveSupport::TestCase
      setup do
        event = events_events(:ready_listing)
        actor = core_users(:super_admin)
        product = Catalog::Products::CreateDraft.call(
          event:,
          actor:,
          product_attributes: { name: "Revision ticket", type: "ticket" },
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
          identity_digest: "c" * 64,
          package_quantity: 1,
          admissions_per_unit_snapshot: 1,
          party_size: 1,
          status: "pending_payment",
          submitted_at: Time.current
        )
        form = RegistrationForm.create!(event:, name: "Revision details", active: true)
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
          submitted_by_user: core_users(:support),
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
        @answer = submission.answers.create!(
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
        @actor = actor
      end

      test "appends a revision without changing the original answer" do
        subject = -> {
          Revise.call(
            answer: @answer,
            revised_by: @actor,
            value: " Corrected ",
            source: "manager_correction",
            reason_code: "data_quality",
            idempotency_key: "revision-command-1"
          )
        }

        assert_idempotent(subject, counter: -> { @answer.revisions.count })
        revision = @answer.reload.revisions.first

        assert_equal 1, revision.revision_number
        assert_equal "Corrected", revision.answer
        assert_equal "Original", @answer.reload.answer
        assert_equal "Corrected", @answer.effective_answer
        assert_equal 1, @answer.revisions.count
      end

      test "rejects a manager correction from an unauthorized attendee" do
        result = Revise.call(
          answer: @answer,
          revised_by: core_users(:attendee),
          value: "No access",
          source: "manager_correction",
          reason_code: "data_quality",
          idempotency_key: "revision-command-unauthorized"
        )

        assert_predicate result, :failure?
        assert_equal "not_authorized", result.error.code
      end

      test "allows the registration owner to correct an answer submitted on their behalf" do
        result = Revise.call(
          answer: @answer,
          revised_by: core_users(:attendee),
          value: "Owner correction",
          source: "attendee_correction",
          idempotency_key: "revision-command-on-behalf"
        )

        assert_predicate result, :success?
        assert_equal "Owner correction", result.value.answer
      end

      test "replays the same request after the correction window closes" do
        key = "revision-command-late-replay"
        first = Revise.call(
          answer: @answer,
          revised_by: core_users(:attendee),
          value: "Corrected",
          source: "attendee_correction",
          idempotency_key: key
        )
        @answer.registration_form_submission.registration.event.event_dates.create!(
          starts_at: 1.hour.ago,
          ends_at: 30.minutes.ago,
          status: "completed"
        )

        replay = Revise.call(
          answer: @answer,
          revised_by: core_users(:attendee),
          value: "Corrected",
          source: "attendee_correction",
          idempotency_key: key
        )

        assert_predicate first, :success?
        assert_predicate replay, :success?
        assert_equal first.value.id, replay.value.id
      end

      test "validates a revision against the original question type" do
        result = Revise.call(
          answer: @answer,
          revised_by: @actor,
          value: { "unexpected" => "object" },
          source: "manager_correction",
          reason_code: "data_quality",
          idempotency_key: "revision-command-invalid"
        )

        assert_predicate result, :failure?
        assert_equal "invalid_answer_revision", result.error.code
      end

      test "rejects a conflicting replay of an idempotency key" do
        first = Revise.call(
          answer: @answer,
          revised_by: @actor,
          value: "Corrected",
          source: "manager_correction",
          reason_code: "data_quality",
          idempotency_key: "revision-command-conflict"
        )
        conflicting = Revise.call(
          answer: @answer,
          revised_by: @actor,
          value: "Different",
          source: "manager_correction",
          reason_code: "data_quality",
          idempotency_key: "revision-command-conflict"
        )

        assert_predicate first, :success?
        assert_predicate conflicting, :failure?
        assert_equal "revision_conflict", conflicting.error.code
      end

      test "rejects an attendee correction after the ticket correction cutoff" do
        @answer.registration_form_submission.registration.event.event_dates.create!(
          starts_at: 1.hour.ago,
          ends_at: 30.minutes.ago,
          status: "completed"
        )

        result = Revise.call(
          answer: @answer,
          revised_by: core_users(:attendee),
          value: "Too late",
          source: "attendee_correction",
          idempotency_key: "revision-command-too-late"
        )

        assert_predicate result, :failure?
        assert_equal "correction_window_closed", result.error.code
      end
    end
  end
end
