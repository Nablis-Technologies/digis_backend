# frozen_string_literal: true

module Ticketing
  # Public review-case projection. Restricted notes and idempotency material
  # stay out of API, audit, and outbox payloads even for authorized managers.
  class TicketSuspensionSerializer < ActiveModel::Serializer
    attributes :id, :ticket_id, :event_id, :initiated_by_id, :reason_code, :status,
               :review_deadline_at, :resolved_by_id, :resolution_reason, :resolved_at,
               :created_at, :updated_at
  end
end
