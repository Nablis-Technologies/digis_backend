# frozen_string_literal: true

module Events
  class StaffInvitationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :staff_invitation

    attributes :id, :event_id, :role, :contact_type, :masked_contact, :status,
               :delivery_status, :delivery_revision, :expires_at, :assignment_expires_at,
               :accepted_at, :revoked_at, :expired_at, :created_at
  end
end
