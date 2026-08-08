# frozen_string_literal: true

module Ticketing
  class RegistrationFormSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    attributes :id, :event_id, :ticket_type_id, :name, :active, :created_at, :updated_at

    has_many :versions, serializer: Ticketing::RegistrationFormVersionSerializer
  end
end
