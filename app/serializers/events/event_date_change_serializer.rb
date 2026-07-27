# frozen_string_literal: true

module Events
  class EventDateChangeSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :event_date_change

    attributes :id, :event_id, :event_date_id, :change_type,
               :old_start_at, :old_end_at, :new_start_at, :new_end_at,
               :scheduled_by_id, :created_at, :updated_at
  end
end
