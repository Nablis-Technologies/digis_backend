# frozen_string_literal: true

module Ticketing
  class RegistrationQuestionSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :registration_form_version_id, :key, :type, :response_scope, :sensitivity,
               :label, :help_text, :required, :position, :options, :validation_rules,
               :created_at, :updated_at
  end
end
