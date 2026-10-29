# frozen_string_literal: true

module Organizations
  class MembershipInvitationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :membership_invitation

    attributes :id, :organization_id, :role, :contact_type, :masked_contact, :status,
               :delivery_status, :delivery_revision, :expires_at, :accepted_at,
               :revoked_at, :expired_at, :created_at
  end
end
