# frozen_string_literal: true

module Ticketing
  class EditableRegistrationAnswerSerializer < ActiveModel::Serializer
    attributes :id, :question_key, :question_label, :question_type, :options,
               :validation_rules, :response_scope, :package_unit_number,
               :admission_position, :admission_slot_id, :editable
    attribute :value, if: :retained_answer?

    def question_key
      object.question_key_snapshot
    end

    def question_label
      object.question_label_snapshot
    end

    def question_type
      object.question_type_snapshot
    end

    def options
      object.registration_question.options
    end

    def validation_rules
      object.registration_question.validation_rules
    end

    def response_scope
      object.response_scope_snapshot
    end

    def value = object.effective_answer

    def editable
      retained_answer? && instance_options[:correction_window_open]
    end

    def retained_answer?
      !object.erased? && !object.retention_expired? && !object.effective_answer.nil?
    end
  end
end
