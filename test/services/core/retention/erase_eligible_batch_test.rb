# frozen_string_literal: true

require "test_helper"

module Core
  module Retention
    class EraseEligibleBatchTest < ActiveSupport::TestCase
      include Ticketing::ConsentTestHelpers
      include Ticketing::AttendeeExportTestHelpers

      setup do
        @event = events_events(:ready_listing)
        @actor = core_users(:super_admin)
        @user = core_users(:attendee)
        @ticket_type = Catalog::Products::CreateDraft.call(
          event: @event,
          actor: @actor,
          product_attributes: { name: "Retention ticket #{SecureRandom.hex(4)}", type: "ticket" },
          ticket_type_attributes: {
            audience: "public", approval_mode: "automatic", date_selection: "fixed", admissions_per_unit: 1
          },
          inventory_configuration: { mode: "unlimited" }
        ).value.ticket_type
        @registration = Ticketing::Registration.create!(
          event: @event,
          ticket_type: @ticket_type,
          user: @user,
          created_by: @user,
          source: "self_service",
          identity_digest: SecureRandom.hex(32),
          package_quantity: 1,
          admissions_per_unit_snapshot: 1,
          party_size: 1,
          status: "pending_payment",
          submitted_at: 31.days.ago
        )
        @policy = Core::DataRetentionPolicy.create!(
          category: "registration_free_text",
          version: 1,
          retention_days: 30,
          action: "erase_payload",
          status: "active",
          effective_at: 32.days.ago,
          created_by: @actor
        )
        @submission, @question = create_submission
        answered_at = 31.days.ago
        @answer = @submission.answers.create!(
          registration_question: @question,
          question_key_snapshot: "name",
          question_type_snapshot: "short_text",
          response_scope_snapshot: "registration",
          question_label_snapshot: "Name",
          answer: "Original",
          retention_policy: @policy,
          retain_until: answered_at + @policy.retention_days.days,
          answered_at:
        )
        @revision = @answer.revisions.create!(
          revision_number: 1,
          answer: "Corrected",
          revised_by: @actor,
          source: "manager_correction",
          reason_code: "data_quality",
          idempotency_key_digest: "1" * 64,
          request_digest: "a" * 64,
          revised_at: answered_at + 1.hour
        )
      end

      test "erases answer and revision payloads while preserving evidence rows" do
        original_deadline = @answer.retain_until
        result = EraseEligibleBatch.call(limit: 10)

        assert_predicate result, :success?
        assert_equal 1, result.value[:answers]
        assert_equal 1, result.value[:revisions]
        assert_equal 0, result.value[:consents]

        answer = @answer.reload
        revision = @revision.reload
        assert answer.erased?
        assert_equal "policy_expiry", answer.erasure_reason
        assert_nil answer.answer_ciphertext
        assert_nil answer.effective_answer
        assert revision.erased?
        assert_nil revision.answer_ciphertext
        assert_equal @registration.id, answer.registration_form_submission.registration_id
        assert_equal original_deadline, answer.retain_until
        assert Ticketing::Registration.exists?(@registration.id)
        assert_equal "pending_payment", @registration.reload.status
      end

      test "invalidates every active attendee export before erasing source answers" do
        statuses = %w[pending processing ready failed]
        exports = statuses.map do |status|
          overrides = { status: }
          overrides[:attempt_count] = 1 if status == "processing"
          create_export(event: @event, actor: @actor, overrides:)
        end

        result = EraseEligibleBatch.call(limit: 10)

        assert_predicate result, :success?, result.error&.message
        assert_equal exports.map(&:id).sort, Ticketing::AttendeeExport.where(status: "expiring").pluck(:id).sort
        assert_equal exports.length, Core::OutboxEvent.where(
          event_type: "ticketing.attendee_export.purge_requested"
        ).count
        assert @answer.reload.erased?
      end

      test "erases a due answer under its retired retention policy snapshot" do
        @policy.update!(status: "retired")

        result = EraseEligibleBatch.call(limit: 10)

        assert_predicate result, :success?
        assert_equal 1, result.value[:answers]
        assert @answer.reload.erased?
      end

      test "does not erase an eligible answer while a matching hold is active" do
        DataRetentionHold.create!(
          event: @event,
          category: "registration_free_text",
          reason_code: "legal_hold",
          placed_by: @actor,
          starts_at: 1.hour.ago,
          idempotency_key: "event-hold-#{SecureRandom.uuid}"
        )

        result = EraseEligibleBatch.call(limit: 10)

        assert_predicate result, :success?
        assert_equal 0, result.value[:answers]
        assert_not @answer.reload.erased?
        assert_not @revision.reload.erased?
      end

      test "does not let held rows starve later eligible rows" do
        second_registration = create_registration
        second_answer = create_answer(question_key: "email", value: "second", registration: second_registration)
        DataRetentionHold.create!(
          registration: @registration,
          category: "registration_free_text",
          reason_code: "legal_hold",
          placed_by: @actor,
          starts_at: 1.hour.ago,
          idempotency_key: "starvation-hold-#{SecureRandom.uuid}"
        )

        result = EraseEligibleBatch.call(limit: 1)

        assert_predicate result, :success?
        assert_equal 1, result.value[:answers]
        assert_not @answer.reload.erased?
        assert second_answer.reload.erased?
      end

      test "does not erase an eligible answer while a category-less user hold is active" do
        DataRetentionHold.create!(
          user: @user,
          reason_code: "security_hold",
          placed_by: @actor,
          starts_at: 1.hour.ago,
          idempotency_key: "user-hold-#{SecureRandom.uuid}"
        )

        result = EraseEligibleBatch.call(limit: 10)

        assert_predicate result, :success?
        assert_equal 0, result.value[:answers]
        assert_not @answer.reload.erased?
      end

      test "does not process more than the requested batch limit" do
        second_answer = create_answer(question_key: "email", value: "second")

        result = EraseEligibleBatch.call(limit: 1)

        assert_predicate result, :success?
        assert_equal 1, result.value[:answers]
        erased_ids = Ticketing::RegistrationAnswer
          .where(id: [ @answer.id, second_answer.id ])
          .where.not(erased_at: nil)
          .pluck(:id)
        assert_equal 1, erased_ids.length
      end

      test "erases consent payload while preserving the consent tombstone" do
        travel_to 31.days.ago do
          setup_consent_context
          _document, version = create_consent_document(scope: "buyer", required: true)
          build_consent_requirements(accept_required_buyer: false)
          requirement = requirement_for(version:, scope: "buyer")
          result = accept_consent(requirement:)
          assert_predicate result, :success?
          @consent = result.value
        end

        result = EraseEligibleBatch.call(limit: 10)

        assert_predicate result, :success?
        assert_equal 1, result.value[:consents]
        consent = @consent.reload
        assert consent.erased_at.present?
        assert_nil consent.accepted_by_user_id
        assert_nil consent.evidence_digest
        assert_nil consent.request_uuid
        assert_equal @registration.id, consent.registration_id
      end

      private

      def create_submission
        form = Ticketing::RegistrationForm.create!(
          event: @event, name: "Retention details #{SecureRandom.hex(4)}", active: true
        )
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
        version.update!(status: "published", published_by: @actor, published_at: 31.days.ago)
        submission = @registration.form_submissions.create!(
          registration_form_version: version,
          submitted_by_user: @user,
          submitted_at: 31.days.ago
        )
        [ submission, question ]
      end

      def create_answer(question_key:, value:, registration: @registration)
        form = Ticketing::RegistrationForm.create!(
          event: @event, name: "Retention details #{SecureRandom.hex(4)}", active: true
        )
        version = form.versions.create!(version: 1, status: "draft")
        question = version.questions.create!(
          key: question_key,
          type: "short_text",
          response_scope: "registration",
          sensitivity: "standard",
          label: question_key.capitalize,
          position: 0,
          options: [],
          validation_rules: {}
        )
        version.update!(status: "published", published_by: @actor, published_at: 31.days.ago)
        submission = registration.form_submissions.create!(
          registration_form_version: version,
          submitted_by_user: @user,
          submitted_at: 31.days.ago
        )
        answered_at = 31.days.ago
        submission.answers.create!(
          registration_question: question,
          question_key_snapshot: question.key,
          question_type_snapshot: question.type,
          response_scope_snapshot: question.response_scope,
          question_label_snapshot: question.label,
          answer: value,
          retention_policy: @policy,
          retain_until: answered_at + @policy.retention_days.days,
          answered_at:
        )
      end

      def create_registration
        Ticketing::Registration.create!(
          event: @event,
          ticket_type: @ticket_type,
          user: @user,
          created_by: @user,
          source: "self_service",
          identity_digest: SecureRandom.hex(32),
          package_quantity: 1,
          admissions_per_unit_snapshot: 1,
          party_size: 1,
          status: "pending_payment",
          submitted_at: 31.days.ago
        )
      end
    end
  end
end
