# frozen_string_literal: true

require "test_helper"

module Ticketing
  class RegistrationQuestionTest < ActiveSupport::TestCase
    test "allows only launch question types and sensitivities" do
      question = RegistrationQuestion.new(
        key: "medical_history",
        type: "medical",
        response_scope: "registration",
        sensitivity: "medical",
        label: "Medical history",
        position: 0,
        options: [],
        validation_rules: {}
      )

      assert_not question.valid?
      assert question.errors.key?(:type)
      assert question.errors.key?(:sensitivity)
    end

    test "requires stable options for choice questions" do
      question = RegistrationQuestion.new(
        key: "meal",
        type: "single_choice",
        response_scope: "registration",
        sensitivity: "standard",
        label: "Meal",
        position: 0,
        options: [ { "label" => "Vegetarian" } ],
        validation_rules: {}
      )

      assert_not question.valid?
      assert question.errors.key?(:options)
    end

    test "restricts validation rules to the question type" do
      question = RegistrationQuestion.new(
        key: "consent",
        type: "checkbox",
        response_scope: "registration",
        sensitivity: "standard",
        label: "Consent",
        position: 0,
        options: [],
        validation_rules: { "min_length" => 1 }
      )

      assert_not question.valid?
      assert question.errors.key?(:validation_rules)
    end

    test "requires ordered item bounds" do
      question = RegistrationQuestion.new(
        key: "meal",
        type: "multiple_choice",
        response_scope: "registration",
        sensitivity: "standard",
        label: "Meal",
        position: 0,
        options: [ { "key" => "standard", "label" => "Standard" } ],
        validation_rules: { "min_items" => 2, "max_items" => 1 }
      )

      assert_not question.valid?
      assert question.errors.key?(:validation_rules)
    end
  end
end
