# frozen_string_literal: true

module Ticketing
  # Safe invitation metadata. Contact ciphertext, contact digests, and link
  # token digests are intentionally excluded from every serialized response.
  class InvitationSerializer < ActiveModel::Serializer
    attributes :id, :ticket_type_id, :invited_user_id, :name, :allowed_quantity,
               :status, :expires_at, :accepted_at, :created_by_id,
               :created_at, :updated_at
  end
end
