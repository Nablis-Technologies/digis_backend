# frozen_string_literal: true

module Ticketing
  class RegistrationAnswerRevisionSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :registration_answer_id, :revision_number, :revised_by_id, :source,
               :reason_code, :revised_at, :erased_at, :created_at, :updated_at
  end
end
