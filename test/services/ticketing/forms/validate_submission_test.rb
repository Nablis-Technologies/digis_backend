# frozen_string_literal: true

require "test_helper"

module Ticketing
  module Forms
    class ValidateSubmissionTest < ActiveSupport::TestCase
      test "requires every slot-scoped answer for every package admission" do
        schema = [
          {
            key: "accessibility",
            type: "short_text",
            response_scope: "admission_slot",
            required: true
          }
        ]
        submission = {
          package_quantity: 1,
          admissions_per_unit: 3,
          answers: [
            { question_key: "accessibility", package_unit_number: 1, admission_position: 1, value: "None" }
          ]
        }

        result = ValidateSubmission.call(schema:, submission:)

        assert_predicate result, :failure?
        assert_equal "incomplete_slot_answers", result.error.code
      end

      test "rejects a registration answer for a question that is not in the schema" do
        schema = [
          {
            key: "meal",
            type: "single_choice",
            response_scope: "registration",
            required: false,
            options: [ { "key" => "standard", "label" => "Standard" } ]
          }
        ]
        submission = {
          package_quantity: 1,
          admissions_per_unit: 1,
          answers: [ { question_key: "unknown", value: "ignored" } ]
        }

        result = ValidateSubmission.call(schema:, submission:)

        assert_predicate result, :failure?
        assert_equal "unknown_question", result.error.code
      end

      test "rejects a draft form version as stale input" do
        form = Ticketing::RegistrationForm.new(event: events_events(:ready_listing), name: "Draft")
        version = Ticketing::RegistrationFormVersion.new(registration_form: form, version: 1, status: "draft")

        result = ValidateSubmission.call(
          schema: [ version ],
          submission: { package_quantity: 1, admissions_per_unit: 1, answers: [] }
        )

        assert_predicate result, :failure?
        assert_equal "stale_form_version", result.error.code
      end

      test "rejects a schema entry with null questions" do
        result = ValidateSubmission.call(
          schema: [ { questions: nil } ],
          submission: { package_quantity: 1, admissions_per_unit: 1, answers: [] }
        )

        assert_predicate result, :failure?
        assert_equal "invalid_schema", result.error.code
      end

      test "rejects duplicate allowed option keys during submission validation" do
        result = ValidateSubmission.call(
          schema: [
            {
              key: "meal",
              type: "multiple_choice",
              response_scope: "registration",
              required: false,
              options: [
                { "key" => "standard", "label" => "Standard" },
                { "key" => "vegan", "label" => "Vegan" }
              ],
              validation_rules: { "allowed_option_keys" => %w[standard standard] }
            }
          ],
          submission: { package_quantity: 1, admissions_per_unit: 1, answers: [] }
        )

        assert_predicate result, :failure?
        assert_equal "invalid_validation_rules", result.error.code
      end

      test "returns a typed failure for nil submission input" do
        result = ValidateSubmission.call(schema: [], submission: nil)

        assert_predicate result, :failure?
        assert_equal "invalid_submission", result.error.code
      end

      test "allows the same question key when form version coordinates disambiguate it" do
        schema = [
          {
            form_version_id: "version-a",
            key: "name",
            type: "short_text",
            response_scope: "registration",
            required: true,
            options: [],
            validation_rules: {}
          },
          {
            form_version_id: "version-b",
            key: "name",
            type: "short_text",
            response_scope: "registration",
            required: true,
            options: [],
            validation_rules: {}
          }
        ]

        result = ValidateSubmission.call(
          schema:,
          submission: {
            package_quantity: 1,
            admissions_per_unit: 1,
            answers: [
              { form_version_id: "version-a", question_key: "name", value: "Ada" },
              { form_version_id: "version-b", question_key: "name", value: "Adoniyas" }
            ]
          }
        )

        assert_predicate result, :success?
        assert_equal 2, result.value.length
      end
    end
  end
end
