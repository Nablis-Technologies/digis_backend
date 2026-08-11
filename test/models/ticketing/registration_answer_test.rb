# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationAnswerTest < ActiveSupport::TestCase
    setup do
      @event = events_events(:ready_listing)
      @user = core_users(:attendee)
      @ticket_type = Catalog::Products::CreateDraft.call(
        event: @event,
        actor: core_users(:super_admin),
        product_attributes: { name: "Registration ticket", type: "ticket" },
        ticket_type_attributes: {
          audience: "public", approval_mode: "automatic", date_selection: "fixed",
          admissions_per_unit: 1
        },
        inventory_configuration: { mode: "unlimited" }
      ).value.ticket_type
      @product = @ticket_type.event_product
      @registration = Registration.create!(
        event: @event,
        ticket_type: @ticket_type,
        user: @user,
        created_by: @user,
        source: "self_service",
        identity_digest: "b" * 64,
        package_quantity: 1,
        admissions_per_unit_snapshot: 1,
        party_size: 1,
        status: "pending_payment",
        submitted_at: Time.current
      )
      @form = RegistrationForm.create!(event: @event, name: "Attendee answers", active: true)
      @version = @form.versions.create!(
        version: 1,
        status: "draft"
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
      @version.update!(
        status: "published",
        published_by: core_users(:super_admin),
        published_at: Time.current
      )
      @submission = @registration.form_submissions.create!(
        registration_form_version: @version,
        submitted_by_user: @user,
        submitted_at: Time.current
      )
      @policy = Core::DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.minute.ago,
        created_by: core_users(:super_admin)
      )
    end

    test "stores canonical encrypted JSON and appends encrypted revisions" do
      answered_at = Time.current
      answer = @submission.answers.create!(
        registration_question: @question,
        question_key_snapshot: "name",
        question_type_snapshot: "short_text",
        response_scope_snapshot: "registration",
        question_label_snapshot: "Name",
        answer: { "last" => "User", "first" => "Ada" },
        retention_policy: @policy,
        retain_until: answered_at + @policy.retention_days.days,
        answered_at:
      )

      assert_equal({ "first" => "Ada", "last" => "User" }, answer.answer)
      stored = ActiveRecord::Base.connection.select_value(
        "SELECT answer_ciphertext FROM ticketing_registration_answers WHERE id = '#{answer.id}'"
      )
      refute_equal '{"first":"Ada","last":"User"}', stored

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationAnswer.transaction(requires_new: true) do
          Ticketing::RegistrationAnswer.where(id: answer.id).update_all(question_label_snapshot: "Changed")
        end
      end

      revision = answer.revisions.create!(
        revision_number: 1,
        answer: "Corrected",
        revised_by: core_users(:super_admin),
        source: "manager_correction",
        reason_code: "attendee_request",
        idempotency_key_digest: "1" * 64,
        request_digest: "a" * 64,
        revised_at: Time.current
      )

      assert_equal "Corrected", revision.answer

      answer.revisions.create!(
        revision_number: 2,
        answer: false,
        revised_by: core_users(:super_admin),
        source: "manager_correction",
        reason_code: "data_quality",
          idempotency_key_digest: "2" * 64,
          request_digest: "b" * 64,
        revised_at: Time.current
      )
      assert_equal false, answer.reload.effective_answer

      assert_raises(ActiveRecord::StatementInvalid) do
        answer.revisions.create!(
          revision_number: 4,
          answer: "Out of order",
          revised_by: core_users(:super_admin),
          source: "manager_correction",
          reason_code: "data_quality",
          idempotency_key_digest: "4" * 64,
          request_digest: "d" * 64,
          revised_at: Time.current
        )
      end

      answer.update!(answer_ciphertext: nil, erased_at: Time.current, erasure_reason: "privacy_request")
      assert_nil answer.reload.effective_answer

      assert_raises(ActiveRecord::StatementInvalid) do
        Ticketing::RegistrationAnswerRevision.transaction(requires_new: true) do
          Ticketing::RegistrationAnswerRevision.where(id: revision.id).update_all(reason_code: "changed")
        end
      end
    end

    test "does not advertise the deferred admission slot association" do
      refute_includes RegistrationAnswer.ransackable_associations, "admission_slot"
    end

    test "database enforces the original retention deadline on revisions" do
      answered_at = Time.current
      answer = @submission.answers.create!(
        registration_question: @question,
        question_key_snapshot: "name",
        question_type_snapshot: "short_text",
        response_scope_snapshot: "registration",
        question_label_snapshot: "Name",
        answer: "Original",
        retention_policy: @policy,
        retain_until: answered_at + 30.days,
        answered_at:
      )
      ciphertext = ActiveRecord::Base.connection.select_value(
        "SELECT answer_ciphertext FROM ticketing_registration_answers WHERE id = '#{answer.id}'"
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        RegistrationAnswerRevision.insert_all!([
          {
            id: SecureRandom.uuid,
            registration_answer_id: answer.id,
            revision_number: 1,
            answer_ciphertext: ciphertext,
            revised_by_id: core_users(:super_admin).id,
            source: "manager_correction",
            reason_code: "data_quality",
            idempotency_key_digest: "6" * 64,
            request_digest: "f" * 64,
            revised_at: Time.current,
            retain_until: answer.retain_until + 1.day,
            created_at: Time.current,
            updated_at: Time.current
          }
        ])
      end
    end

    test "database keeps answers attached to their submission version" do
      other_form = RegistrationForm.create!(event: @event, name: "Other answers", active: true)
      other_version = other_form.versions.create!(version: 1, status: "draft")
      other_question = other_version.questions.create!(
        key: "other_name",
        type: "short_text",
        response_scope: "registration",
        sensitivity: "standard",
        label: "Other name",
        position: 0,
        options: [],
        validation_rules: {}
      )
      other_version.update!(status: "published", published_by: core_users(:super_admin), published_at: Time.current)

      assert_raises(ActiveRecord::StatementInvalid) do
        RegistrationAnswer.transaction(requires_new: true) do
          RegistrationAnswer.insert_all!([
            {
              id: SecureRandom.uuid,
              registration_form_submission_id: @submission.id,
              registration_question_id: other_question.id,
              question_key_snapshot: "other_name",
              question_type_snapshot: "short_text",
              response_scope_snapshot: "registration",
              question_label_snapshot: "Other name",
              answer_ciphertext: "invalid-ciphertext",
              retention_policy_id: @policy.id,
              retain_until: Time.current + 30.days,
              answered_at: Time.current,
              created_at: Time.current,
              updated_at: Time.current
            }
          ])
        end
      end
    end

    test "does not allow an answer deadline to outlive its retention policy" do
      answered_at = Time.current
      answer = @submission.answers.build(
        registration_question: @question,
        question_key_snapshot: "name",
        question_type_snapshot: "short_text",
        response_scope_snapshot: "registration",
        question_label_snapshot: "Name",
        answer: "Ada",
        retention_policy: @policy,
        retain_until: answered_at + 60.days,
        answered_at:
      )

      assert_not answer.valid?
      assert answer.errors.key?(:retain_until)
    end

    test "requires an active category-matching effective retention policy" do
      draft_policy = Core::DataRetentionPolicy.create!(
        category: "registration_free_text",
        version: 2,
        retention_days: 30,
        action: "erase_payload",
        status: "draft",
        created_by: core_users(:super_admin)
      )
      answer = @submission.answers.build(
        registration_question: @question,
        question_key_snapshot: "name",
        question_type_snapshot: "short_text",
        response_scope_snapshot: "registration",
        question_label_snapshot: "Name",
        answer: "Ada",
        retention_policy: draft_policy,
        retain_until: 30.days.from_now,
        answered_at: Time.current
      )

      assert_not answer.valid?
      assert answer.errors.key?(:retention_policy)

      structured_policy = Core::DataRetentionPolicy.create!(
        category: "registration_structured",
        version: 1,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.minute.ago,
        created_by: core_users(:super_admin)
      )
      answer.retention_policy = structured_policy
      assert_not answer.valid?
      assert answer.errors.key?(:retention_policy)
    end

    test "rejects a future-effective retention policy" do
      policy = Core::DataRetentionPolicy.create!(
        category: "registration_free_text",
        jurisdiction_code: "ET",
        version: 2,
        retention_days: 30,
        action: "erase_payload",
        status: "active",
        effective_at: 1.day.from_now,
        created_by: core_users(:super_admin)
      )
      answer = @submission.answers.build(
        registration_question: @question,
        question_key_snapshot: "name",
        question_type_snapshot: "short_text",
        response_scope_snapshot: "registration",
        question_label_snapshot: "Name",
        answer: "Ada",
        retention_policy: policy,
        retain_until: 30.days.from_now,
        answered_at: Time.current
      )

      assert_not answer.valid?
      assert answer.errors.key?(:retention_policy)
    end

    test "does not expose an effective answer after its retention deadline" do
      answered_at = Time.current
      answer = @submission.answers.create!(
        registration_question: @question,
        question_key_snapshot: "name",
        question_type_snapshot: "short_text",
        response_scope_snapshot: "registration",
        question_label_snapshot: "Name",
        answer: "Original",
        retention_policy: @policy,
        retain_until: answered_at + 30.days,
        answered_at:
      )
      answer.revisions.create!(
        revision_number: 1,
        answer: "Corrected",
        revised_by: core_users(:super_admin),
        source: "manager_correction",
        reason_code: "data_quality",
        idempotency_key_digest: "5" * 64,
        request_digest: "e" * 64,
        revised_at: Time.current
      )

      travel_to(answer.retain_until + 1.second) do
        assert_nil answer.reload.effective_answer
      end
    end
  end
end
