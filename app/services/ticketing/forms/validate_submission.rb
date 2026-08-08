# frozen_string_literal: true

module Ticketing
  module Forms
    # Validates untrusted form payloads against a published question schema and
    # returns canonical answer values. It supports both registration-wide and
    # per-admission answers while rejecting ambiguous question coordinates.
    class ValidateSubmission < Core::BaseService
      QUESTION_TYPES = Ticketing::RegistrationQuestion::TYPES
      RESPONSE_SCOPES = Ticketing::RegistrationQuestion::RESPONSE_SCOPES
      VALIDATION_RULE_KEYS = Ticketing::RegistrationQuestion::VALIDATION_RULE_KEYS
      QUESTION_KEY = /\A[a-z][a-z0-9_]*\z/
      INTEGER_RULES = %w[min_length max_length min_items max_items].freeze
      TEXT_TYPES = %w[short_text long_text].freeze

      def initialize(schema:, submission:)
        @schema = Array(schema)
        @submission = attributes_for(submission)
      end

      def call
        return failure_for("invalid_submission") unless submission

        schema_result = normalized_schema
        return schema_result if schema_result.failure?

        package_quantity = positive_integer(@submission[:package_quantity])
        admissions_per_unit = positive_integer(@submission[:admissions_per_unit])
        return failure_for("invalid_submission") unless package_quantity && admissions_per_unit

        raw_answers = normalized_input_answers(@submission[:answers])
        return failure_for("invalid_submission") unless raw_answers

        answers_result = normalize_answers(
          schema_result.value,
          raw_answers,
          package_quantity,
          admissions_per_unit
        )
        return answers_result if answers_result.failure?

        required_result = validate_required_answers(
          schema_result.value,
          answers_result.value,
          package_quantity,
          admissions_per_unit
        )
        return required_result if required_result.failure?

        success(answers_result.value)
      end

      private

      attr_reader :schema, :submission

      def normalized_schema
        return failure_for("stale_form_version") if schema.any? { |entry| stale_version?(entry) }

        eager_questions = eager_questions_by_version
        expanded = schema.map { |entry| expand_schema_entry(entry, eager_questions) }
        return failure_for("invalid_schema") if expanded.any?(&:nil?)

        questions = expanded.flatten
        normalized = questions.map do |question|
          normalize_question(question)
        end

        error = normalized.find { |_, result| result.failure? }&.last
        return error if error

        values = normalized.map(&:first)
        # A key may recur across form versions, but never inside the same
        # version: otherwise a submitted answer would not identify one question.
        schema_keys = values.map { |question| [ question[:form_version_id], question[:key] ] }
        return failure_for("duplicate_question") unless schema_keys.uniq.length == schema_keys.length

        success(values)
      end

      def stale_version?(entry)
        return false unless entry.respond_to?(:published?)

        !entry.published? || (entry.respond_to?(:registration_form) && !entry.registration_form.active?)
      end

      def eager_questions_by_version
        versions = schema.select do |entry|
          entry.respond_to?(:questions) &&
            entry.respond_to?(:association) &&
            !entry.association(:questions).loaded?
        end
        ids = versions.map(&:id).compact
        return {} if ids.empty?

        Ticketing::RegistrationQuestion
          .where(registration_form_version_id: ids)
          .order(:registration_form_version_id, :position)
          .to_a
          .group_by(&:registration_form_version_id)
      end

      def expand_schema_entry(entry, eager_questions)
        if entry.is_a?(Hash)
          entry_attributes = attributes_for(entry)
          return entry_attributes[:questions] if entry_attributes.key?(:questions) &&
            entry_attributes[:questions].is_a?(Array)
          return if entry_attributes.key?(:questions)
        elsif entry.respond_to?(:questions)
          return eager_questions.fetch(entry.id) { questions_for_version(entry) }
        end

        [ entry ]
      end

      def questions_for_version(version)
        if version.respond_to?(:association) && version.association(:questions).loaded?
          return version.association(:questions).target
        end

        Ticketing::RegistrationQuestion
          .where(registration_form_version_id: version.id)
          .order(:position)
          .to_a
      end

      def normalize_question(question)
        attributes = question_attributes(question)
        return [ nil, failure_for("invalid_schema") ] unless attributes

        key = attributes[:key].to_s
        return [ nil, failure_for("invalid_schema") ] unless key.match?(QUESTION_KEY)

        type = attributes[:type].to_s
        return [ nil, failure_for("invalid_type") ] unless QUESTION_TYPES.include?(type)

        response_scope = attributes[:response_scope].to_s
        return [ nil, failure_for("invalid_scope") ] unless RESPONSE_SCOPES.include?(response_scope)
        return [ nil, failure_for("stale_form_version") ] if question.respond_to?(:published?) && !question.published?

        required = attributes.key?(:required) ? attributes[:required] : false
        return [ nil, failure_for("invalid_schema") ] unless [ true, false ].include?(required)

        options_result = normalize_options(attributes.fetch(:options, []), type)
        return [ nil, options_result ] if options_result.failure?

        rules_result = normalize_rules(attributes.fetch(:validation_rules, {}), type, options_result.value)
        return [ nil, rules_result ] if rules_result.failure?

        [
          {
            form_version_id: attributes[:form_version_id],
            key: key,
            type: type,
            response_scope: response_scope,
            required: required,
            option_keys: options_result.value,
            validation_rules: rules_result.value
          },
          success
        ]
      end

      def question_attributes(question)
        return attributes_for(question) if question.is_a?(Hash)
        return unless question.respond_to?(:key) && question.respond_to?(:type)

        {
          form_version_id: question.registration_form_version_id,
          key: question.key,
          type: question.type,
          response_scope: question.response_scope,
          required: question.required,
          options: question.options,
          validation_rules: question.validation_rules
        }
      end

      def normalize_options(raw_options, type)
        return failure_for("invalid_schema") unless raw_options.is_a?(Array)

        keys = raw_options.map do |option|
          option_attributes = attributes_for(option)
          option_key = if option.is_a?(String)
            option
          elsif option_attributes
            option_attributes[:key]
          end
          option_key.to_s
        end

        invalid = keys.any? { |key| !key.match?(QUESTION_KEY) }
        invalid ||= keys.uniq.length != keys.length
        invalid ||= !%w[single_choice multiple_choice].include?(type) && keys.any?
        invalid ||= %w[single_choice multiple_choice].include?(type) && keys.empty?
        return failure_for("invalid_schema") if invalid

        success(keys)
      end

      def normalize_rules(raw_rules, type, option_keys)
        return failure_for("invalid_validation_rules") unless raw_rules.is_a?(Hash)

        rules = raw_rules.stringify_keys
        return failure_for("invalid_validation_rules") if (rules.keys - VALIDATION_RULE_KEYS).any?

        return failure_for("invalid_validation_rules") unless valid_integer_rules?(rules)
        return failure_for("invalid_validation_rules") unless valid_rule_scope?(rules, type)
        return failure_for("invalid_validation_rules") unless valid_allowed_options?(rules, type, option_keys)
        return failure_for("invalid_validation_rules") unless valid_date_rules?(rules, type)

        success(rules)
      end

      def valid_integer_rules?(rules)
        return false unless INTEGER_RULES.all? do |key|
          !rules.key?(key) || rules[key].is_a?(Integer) && rules[key] >= 0
        end

        %w[min_length min_items].all? do |minimum|
          maximum = minimum.sub("min", "max")
          !rules.key?(minimum) || !rules.key?(maximum) || rules[maximum] >= rules[minimum]
        end
      end

      def valid_rule_scope?(rules, type)
        return false if (rules.keys & %w[min_length max_length]).any? && !TEXT_TYPES.include?(type)
        return false if (rules.keys & %w[min_items max_items]).any? && type != "multiple_choice"
        return false if rules.key?("allowed_option_keys") && !%w[single_choice multiple_choice].include?(type)
        return false if (rules.keys & %w[min_date max_date]).any? && type != "date"

        true
      end

      def valid_allowed_options?(rules, type, option_keys)
        return true unless rules.key?("allowed_option_keys")
        return false unless %w[single_choice multiple_choice].include?(type)

        allowed = rules["allowed_option_keys"]
        allowed.is_a?(Array) &&
          allowed.all? { |key| key.is_a?(String) && key.match?(QUESTION_KEY) && option_keys.include?(key) } &&
          allowed.uniq.length == allowed.length
      end

      def valid_date_rules?(rules, type)
        return true unless (rules.keys & %w[min_date max_date]).any?
        return false unless type == "date"

        dates = rules.values_at("min_date", "max_date").compact
        return false unless dates.all? { |date| date.is_a?(String) && Date.iso8601(date) }
        return true unless rules.key?("min_date") && rules.key?("max_date")

        Date.iso8601(rules["max_date"]) >= Date.iso8601(rules["min_date"])
      rescue Date::Error, ArgumentError
        false
      end

      def normalize_answers(questions, raw_answers, package_quantity, admissions_per_unit)
        seen = {}
        normalized = []

        raw_answers.each do |raw_answer|
          answer = attributes_for(raw_answer)
          return failure_for("invalid_submission") unless answer

          key = answer[:question_key].to_s
          question_result = question_for_answer(questions, answer)
          return question_result if question_result.failure?

          question = question_result.value

          coordinates_result = normalize_coordinates(
            question,
            answer,
            package_quantity,
            admissions_per_unit
          )
          return coordinates_result if coordinates_result.failure?

          coordinates = coordinates_result.value
          duplicate_key = [
            question[:form_version_id], key,
            coordinates[:package_unit_number], coordinates[:admission_position]
          ]
          return failure_for("duplicate_answer") if seen.key?(duplicate_key)

          seen[duplicate_key] = true
          value = answer[:value]
          unless answer_value_present?(value)
            return failure_for("required_answer") if question[:required]

            next
          end

          value_result = normalize_value(question, value)
          return value_result if value_result.failure?

          normalized_answer = { question_key: key, value: value_result.value }
          normalized_answer[:form_version_id] = question[:form_version_id] if question[:form_version_id].present?
          normalized_answer.merge!(coordinates) if question[:response_scope] == "admission_slot"
          normalized << normalized_answer
        end

        success(normalized)
      end

      def question_for_answer(questions, answer)
        candidates = questions.select { |question| question[:key] == answer[:question_key].to_s }
        return failure_for("unknown_question") if candidates.empty?

        form_version_id = answer[:form_version_id].to_s.presence
        if form_version_id
          question = candidates.find { |candidate| candidate[:form_version_id].to_s == form_version_id }
          return failure_for("unknown_question") unless question

          return success(question)
        end

        return failure_for("duplicate_question") if candidates.length > 1

        success(candidates.first)
      end

      def normalize_coordinates(question, answer, package_quantity, admissions_per_unit)
        unit = answer[:package_unit_number]
        position = answer[:admission_position]
        unit_present = coordinate_present?(unit)
        position_present = coordinate_present?(position)

        if question[:response_scope] == "registration"
          return failure_for("invalid_scope") if unit_present || position_present

          return success({ package_unit_number: nil, admission_position: nil })
        end

        return failure_for("invalid_coordinates") unless unit_present && position_present

        normalized_unit = positive_integer(unit)
        normalized_position = positive_integer(position)
        return failure_for("invalid_coordinates") unless normalized_unit && normalized_position
        return failure_for("invalid_coordinates") if normalized_unit > package_quantity
        return failure_for("invalid_coordinates") if normalized_position > admissions_per_unit

        success(package_unit_number: normalized_unit, admission_position: normalized_position)
      end

      def normalize_value(question, value)
        case question[:type]
        when "short_text", "long_text"
          return failure_for("invalid_type") unless value.is_a?(String)

          normalized = value.strip
          return failure_for("invalid_value") unless valid_length?(normalized, question[:validation_rules])

          success(normalized)
        when "single_choice"
          return failure_for("invalid_type") unless value.is_a?(String)

          normalized = value.strip
          return failure_for("invalid_choice") unless allowed_options(question).include?(normalized)

          success(normalized)
        when "multiple_choice"
          return failure_for("invalid_type") unless value.is_a?(Array)

          normalized = value.map { |choice| choice.strip if choice.is_a?(String) }
          return failure_for("invalid_choice") if normalized.any?(&:nil?) || normalized.any?(&:blank?)
          return failure_for("invalid_choice") if normalized.uniq.length != normalized.length
          return failure_for("invalid_choice") unless normalized.all? { |choice| allowed_options(question).include?(choice) }
          return failure_for("invalid_value") unless valid_item_count?(normalized, question[:validation_rules])

          success(normalized)
        when "checkbox"
          return failure_for("invalid_type") unless [ true, false ].include?(value)

          success(value)
        when "date"
          return failure_for("invalid_type") unless value.is_a?(String)

          normalized = Date.iso8601(value).iso8601
          return failure_for("invalid_value") unless valid_date_value?(normalized, question[:validation_rules])

          success(normalized)
        else
          failure_for("invalid_type")
        end
      rescue Date::Error, ArgumentError
        failure_for("invalid_type")
      end

      def allowed_options(question)
        question[:validation_rules]["allowed_option_keys"] || question[:option_keys]
      end

      def valid_length?(value, rules)
        return false if rules["min_length"] && value.length < rules["min_length"]
        return false if rules["max_length"] && value.length > rules["max_length"]

        true
      end

      def valid_item_count?(value, rules)
        return false if rules["min_items"] && value.length < rules["min_items"]
        return false if rules["max_items"] && value.length > rules["max_items"]

        true
      end

      def valid_date_value?(value, rules)
        date = Date.iso8601(value)
        return false if rules["min_date"] && date < Date.iso8601(rules["min_date"])
        return false if rules["max_date"] && date > Date.iso8601(rules["max_date"])

        true
      end

      def validate_required_answers(questions, answers, package_quantity, admissions_per_unit)
        questions.each do |question|
          next unless question[:required]

          question_answers = answers.select { |answer| answer_matches_question?(answer, question) }
          if question[:response_scope] == "registration"
            return failure_for("required_answer") if question_answers.empty?

            next
          end

          expected = package_quantity.times.flat_map do |unit|
            admissions_per_unit.times.map { |position| [ unit + 1, position + 1 ] }
          end
          actual = question_answers.map do |answer|
            [ answer[:package_unit_number], answer[:admission_position] ]
          end
          return failure_for("incomplete_slot_answers") unless (expected - actual).empty?
        end

        success
      end

      def answer_matches_question?(answer, question)
        return false unless answer[:question_key] == question[:key]
        return true if question[:form_version_id].blank?

        answer[:form_version_id].to_s == question[:form_version_id].to_s
      end

      def normalized_input_answers(raw_answers)
        return [] if raw_answers.nil?
        return raw_answers if raw_answers.is_a?(Array)
        return unless raw_answers.is_a?(Hash)

        attributes = attributes_for(raw_answers)
        return [ raw_answers ] if attributes.key?(:question_key)

        raw_answers.map { |key, value| { question_key: key, value: value } }
      end

      def answer_value_present?(value)
        return false if value.nil?
        return false if value.is_a?(String) && value.strip.empty?
        return false if value.is_a?(Array) && value.empty?

        true
      end

      def coordinate_present?(value)
        return false if value.nil?
        return false if value.respond_to?(:empty?) && value.empty?

        true
      end

      def positive_integer(value)
        return value if value.is_a?(Integer) && value.positive?
        return unless value.is_a?(String) && value.match?(/\A[1-9]\d*\z/)

        value.to_i
      end

      def attributes_for(value)
        return if value.nil?
        return value.to_unsafe_h.symbolize_keys if value.respond_to?(:to_unsafe_h)
        return value.to_h.symbolize_keys if value.respond_to?(:to_h)

        nil
      end

      def failure_for(code)
        failure Core::BusinessError.new(
          I18n.t("ticketing.forms.errors.#{code}"),
          code: code,
          status: :unprocessable_entity
        )
      end
    end
  end
end
