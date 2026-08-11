# frozen_string_literal: true

module Ticketing
  module Forms
    # Persists an immutable snapshot of each applicable form and its encrypted
    # answers. The client-provided schema must match the currently locked
    # versions, preventing a stale form from being recorded as current evidence.
    class PersistSubmission < Core::BaseService
      TEXT_TYPES = %w[short_text long_text].freeze

      def initialize(registration:, schema:, submission:, actor:)
        @registration = registration
        @schema = Array(schema)
        @submission = submission&.to_h&.deep_symbolize_keys
        @actor = actor
      end

      def call
        return failure(invalid_submission_error) unless submission

        persisted = RegistrationFormVersion.transaction do
          versions = load_versions
          return failure(stale_schema_error) unless versions

          validation = validate_submission(versions)
          return failure(validation.error) if validation.failure?

          policies = retention_policies(versions, validation.value)
          return failure(policies.error) if policies.failure?

          write_submissions(versions, validation.value, policies.value)
        end

        success(persisted)
      rescue ActiveRecord::RecordInvalid => error
        failure(invalid_submission_error(error.record))
      end

      private

      attr_reader :registration, :schema, :submission, :actor

      def validate_submission(versions)
        ValidateSubmission.call(
          schema: versions,
          submission: submission.merge(
            package_quantity: registration.package_quantity,
            admissions_per_unit: registration.admissions_per_unit_snapshot
          )
        )
      end

      def load_versions
        current_versions = current_applicable_versions
        return unless current_versions

        supplied_ids = schema.filter_map { |entry| entry.id if entry.respond_to?(:id) }
        return unless supplied_ids.sort == current_versions.map(&:id).sort

        current_versions
      end

      def current_applicable_versions
        forms = RegistrationForm
          .active
          .where(event_id: registration.event_id, ticket_type_id: [ nil, registration.ticket_type_id ])
          .order(Arel.sql("ticket_type_id IS NOT NULL"), :created_at, :id)
          .lock
          .to_a
        return [] if forms.empty?

        versions = RegistrationFormVersion
          .published
          .where(registration_form_id: forms.map(&:id))
          .includes(:registration_form, :questions)
          .lock
          .to_a
          .index_by(&:registration_form_id)
        return if forms.any? { |form| versions[form.id].blank? }

        forms.map { |form| versions.fetch(form.id) }
      end

      def retention_policies(versions, answers)
        questions = versions.flat_map(&:questions)
        stored_question_keys = submission_questions(questions, answers)
        categories = stored_question_keys.map { |question| retention_category(question) }.uniq
        selected = {}

        # Retention is selected at submission time and stored on every answer,
        # so later policy changes never rewrite the original retention decision.
        categories.each do |category|
          result = Core::Retention::SelectPolicy.call(category:, jurisdiction_code: nil)
          return result if result.failure?

          selected[category] = result.value
        end

        Core::BaseService::Result.success(selected)
      end

      def submission_questions(questions, answers)
        answers = answers.to_a.map(&:deep_symbolize_keys)
        answers.filter_map do |answer|
          candidates = questions.select { |question| question.key == answer[:question_key].to_s }
          candidates.find do |question|
            answer[:form_version_id].blank? ||
              answer[:form_version_id].to_s == question.registration_form_version_id.to_s
          end
        end.uniq
      end

      def write_submissions(versions, answers, policies)
        versions.map do |version|
          form_submission = RegistrationFormSubmission.create!(
            registration:,
            registration_form_version: version,
            submitted_by_user: actor,
            submitted_at: Time.current
          )
          questions = version.questions.index_by(&:key)
          version_answers = answers.select { |answer| question_for(questions, answer) }
          persist_answers(form_submission, questions, version_answers, policies)
          form_submission
        end
      end

      def persist_answers(form_submission, questions, answers, policies)
        answers.map do |answer|
          question = question_for(questions, answer)
          next unless question

          policy = policies.fetch(retention_category(question))
          answered_at = Time.current
          form_submission.answers.create!(
            registration_question: question,
            question_key_snapshot: question.key,
            question_type_snapshot: question.type,
            response_scope_snapshot: question.response_scope,
            question_label_snapshot: question.label,
            package_unit_number: answer[:package_unit_number],
            admission_position: answer[:admission_position],
            answer: answer[:value],
            retention_policy: policy,
            retain_until: retention_deadline(policy, answered_at),
            answered_at:
          )
        end.compact
      end

      def question_for(questions, answer)
        question = questions[answer[:question_key].to_s]
        return unless question
        return if answer[:form_version_id].present? &&
                  answer[:form_version_id].to_s != question.registration_form_version_id.to_s

        question
      end

      def retention_category(question)
        TEXT_TYPES.include?(question.type) ? "registration_free_text" : "registration_structured"
      end

      def retention_deadline(policy, answered_at)
        return if policy.retention_days.blank?

        answered_at + policy.retention_days.days
      end

      def stale_schema_error
        Core::BusinessError.new(
          I18n.t("ticketing.forms.errors.stale_form_version"),
          code: "stale_form_version",
          status: :unprocessable_entity
        )
      end

      def invalid_submission_error(record = nil)
        Core::BusinessError.new(
          I18n.t("ticketing.forms.errors.invalid_submission"),
          code: "invalid_submission",
          status: :unprocessable_entity,
          errors: record&.errors&.to_hash || {}
        )
      end
    end
  end
end
