# frozen_string_literal: true

module Events
  class EventStaffAssignmentSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :event_staff_assignment

    attributes :id, :role, :status, :user_id, :organization_id, :event_id,
               :created_at, :updated_at
  end
end
