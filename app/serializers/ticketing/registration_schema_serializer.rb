# frozen_string_literal: true

module Ticketing
  class RegistrationSchemaSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :registration_form_id, :version, :status

    has_many :questions, serializer: Ticketing::RegistrationQuestionSerializer
  end
end
