# frozen_string_literal: true

module Ticketing
  module Public
    # Projects the published form contract needed to render registration UI.
    # Submission answers, publication actors, and audit timestamps stay private.
    class RegistrationSchemaSerializer < ActiveModel::Serializer
      attributes :id, :registration_form_id, :form_name, :version, :questions

      def form_name
        object.registration_form.name
      end

      def questions
        object.questions.sort_by { |question| [ question.position, question.id ] }.map do |question|
          {
            id: question.id,
            key: question.key,
            type: question.type,
            response_scope: question.response_scope,
            label: question.label,
            help_text: question.help_text,
            required: question.required,
            position: question.position,
            options: question.options,
            validation_rules: question.validation_rules
          }
        end
      end
    end
  end
end
