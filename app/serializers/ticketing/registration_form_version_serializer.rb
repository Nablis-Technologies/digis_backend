# frozen_string_literal: true

module Ticketing
  class RegistrationFormVersionSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :registration_form_id, :version, :status, :published_by_id, :published_at,
               :created_at, :updated_at

    has_many :questions, serializer: Ticketing::RegistrationQuestionSerializer
  end
end
