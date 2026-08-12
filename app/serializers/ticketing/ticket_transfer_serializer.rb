# frozen_string_literal: true

module Ticketing
  # Safe transfer history projection. The bearer transfer token digest is not
  # an API field even though it remains stored for lookup and replay safety.
  class TicketTransferSerializer < ActiveModel::Serializer
    attributes :id, :ticket_id, :from_user_id, :to_user_id, :initiated_by_id,
               :status, :previous_version, :new_version, :reason, :expires_at,
               :accepted_at, :declined_at, :cancelled_at, :created_at, :updated_at
  end
end
