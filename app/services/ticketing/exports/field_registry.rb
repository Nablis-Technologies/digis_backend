# frozen_string_literal: true

module Ticketing
  module Exports
    # Resolves the closed export field vocabulary and immutable question history.
    class FieldRegistry < Core::BaseService
      BUILT_INS = {
        "registration_id" => {
          authorization: :event_manager,
          row_modes: %w[registration admission],
          heading_key: "ticketing.attendee_exports.fields.registration_id",
          extractor: ->(row) { row.registration.id }
        },
        "registration_status" => {
          authorization: :event_manager,
          row_modes: %w[registration admission],
          heading_key: "ticketing.attendee_exports.fields.registration_status",
          extractor: ->(row) { row.registration.status }
        },
        "ticket_type_id" => {
          authorization: :event_manager,
          row_modes: %w[registration admission],
          heading_key: "ticketing.attendee_exports.fields.ticket_type_id",
          extractor: ->(row) { row.registration.ticket_type_id }
        },
        "selected_event_date_id" => {
          authorization: :event_manager,
          row_modes: %w[registration admission],
          heading_key: "ticketing.attendee_exports.fields.selected_event_date_id",
          extractor: ->(row) { row.registration.selected_event_date_id }
        },
        "package_unit_number" => {
          authorization: :event_manager,
          row_modes: [ "admission" ],
          heading_key: "ticketing.attendee_exports.fields.package_unit_number",
          extractor: ->(row) { row.package_unit_number }
        },
        "admission_position" => {
          authorization: :event_manager,
          row_modes: [ "admission" ],
          heading_key: "ticketing.attendee_exports.fields.admission_position",
          extractor: ->(row) { row.admission_position }
        },
        "registration_user_email" => {
          authorization: "attendee_export.contact",
          row_modes: %w[registration admission],
          heading_key: "ticketing.attendee_exports.fields.registration_user_email",
          extractor: ->(row) { row.registration.user&.email }
        },
        "registration_user_phone" => {
          authorization: "attendee_export.contact",
          row_modes: %w[registration admission],
          heading_key: "ticketing.attendee_exports.fields.registration_user_phone",
          extractor: ->(row) { row.registration.user&.phone }
        }
      }.each_value do |definition|
        definition[:row_modes].freeze
        definition.freeze
      end.freeze

      QUESTION_SELECTOR = /\Aquestion:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):([a-z][a-z0-9_]*)\z/i

      def self.resolve(event:, selectors:, row_mode:)
        new(event:, selectors:, row_mode:).call
      end

      def initialize(event:, selectors:, row_mode:)
        @event = event
        @selectors = selectors
        @row_mode = row_mode.to_s
      end

      def call
        return failure_for(:invalid_field_selector) unless valid_selector_input?

        questions_by_selector = submitted_questions(question_selector_parts)
        definitions = @selectors.map do |selector|
          result = resolve_selector(selector, questions_by_selector)
          return result if result.failure?

          result.value
        end

        success(definitions)
      end

      private

      def valid_selector_input?
        @event.present? && AttendeeExport::ROW_MODES.include?(@row_mode) &&
          @selectors.is_a?(Array) && @selectors.present? &&
          @selectors.all? { |selector| selector.is_a?(String) } &&
          @selectors.uniq.length == @selectors.length
      end

      def resolve_selector(selector, questions_by_selector)
        if BUILT_INS.key?(selector)
          return failure_for(:invalid_field_row_mode) unless BUILT_INS.fetch(selector).fetch(:row_modes).include?(@row_mode)

          return success(built_in_definition(selector))
        end
        parts = question_selector_parts.fetch(selector, nil)
        return failure_for(:invalid_field_selector) unless parts

        resolve_question(selector, questions_by_selector.fetch(parts, []))
      end

      def built_in_definition(selector)
        definition = BUILT_INS.fetch(selector)
        definition.merge(selector: selector, heading: I18n.t(definition.fetch(:heading_key)))
      end

      def resolve_question(selector, questions)
        return failure_for(:invalid_field_selector) if questions.empty?

        fingerprints = questions.map { |question| semantic_fingerprint(question) }.uniq
        return failure_for(:field_definition_conflict) unless fingerprints.one?

        question = questions.first
        response_scope = question.response_scope
        row_modes = response_scope == "registration" ? %w[registration admission] : [ "admission" ]
        return failure_for(:invalid_field_row_mode) unless row_modes.include?(@row_mode)

        success(
          selector: selector,
          authorization: question_authorization(question),
          row_modes: row_modes,
          heading: normalize_text(question.label),
          extractor: ->(row) { row.answer_by_selector&.fetch(selector, nil) }
        )
      end

      def question_selector_parts
        @selectors.filter_map do |selector|
          match = selector.match(QUESTION_SELECTOR)
          [ selector, [ match[1].downcase, match[2] ] ] if match
        end.to_h
      end

      def submitted_questions(selector_parts)
        return {} if selector_parts.empty?

        submitted_version_ids = RegistrationFormSubmission
          .joins(:registration)
          .where(ticketing_registrations: { event_id: @event.id })
          .select(:registration_form_version_id)
        form_ids = selector_parts.values.map(&:first).uniq
        keys = selector_parts.values.map(&:last).uniq

        questions = RegistrationQuestion
          .joins(registration_form_version: :registration_form)
          .where(registration_form_version_id: submitted_version_ids, key: keys)
          .where(
            ticketing_registration_form_versions: { registration_form_id: form_ids, status: %w[published retired] },
            ticketing_registration_forms: { event_id: @event.id }
          )
          .includes(:registration_form_version)
          .to_a

        questions.group_by do |question|
          [ question.registration_form_version.registration_form_id, question.key ]
        end
      end

      def question_authorization(question)
        {
          "standard" => :event_manager,
          "dietary" => "attendee_export.dietary",
          "accessibility" => "attendee_export.accessibility"
        }.fetch(question.sensitivity)
      end

      def semantic_fingerprint(question)
        {
          "key" => question.key,
          "type" => question.type,
          "response_scope" => question.response_scope,
          "sensitivity" => question.sensitivity,
          "label" => normalize_text(question.label),
          "help_text" => question.help_text.nil? ? nil : normalize_text(question.help_text),
          "required" => question.required,
          "options" => canonical_options(question.options),
          "validation_rules" => canonical_value(question.validation_rules)
        }
      end

      def canonical_options(options)
        options
          .map { |option| { "key" => option.fetch("key"), "label" => normalize_text(option.fetch("label")) } }
          .sort_by { |option| option.fetch("key") }
      end

      def canonical_value(value, parent_key = nil)
        case value
        when Hash
          value.stringify_keys.keys.sort.each_with_object({}) do |key, result|
            child = value.key?(key) ? value[key] : value[key.to_sym]
            result[key] = canonical_value(child, key)
          end
        when Array
          values = value.map { |child| canonical_value(child, parent_key) }
          parent_key == "allowed_option_keys" ? values.sort : values
        when String
          normalize_text(value)
        else
          value
        end
      end

      def normalize_text(value)
        value.to_s.unicode_normalize(:nfc).gsub(/\p{Space}+/u, " ").strip
      end

      def failure_for(code)
        failure(
          Core::BusinessError.new(
            I18n.t("ticketing.attendee_exports.errors.#{code}"),
            code: code,
            status: :unprocessable_entity
          )
        )
      end
    end
  end
end
