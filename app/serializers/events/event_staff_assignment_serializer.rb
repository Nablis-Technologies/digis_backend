# frozen_string_literal: true

module Events
  class EventStaffAssignmentSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :event_staff_assignment

    attributes :id, :role, :status, :user_id, :organization_id, :event_id,
               :created_at, :updated_at

    attribute :user do
      next unless object.user

      { id: object.user.id, email: object.user.email, phone: object.user.phone }
    end

    attribute :organization do
      next unless object.organization

      Events::Public::OrganizationSummarySerializer.new(object.organization).attributes
    end
  end
end
