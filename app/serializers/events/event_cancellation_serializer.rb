# frozen_string_literal: true

module Events
  class EventCancellationSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :event_cancellation

    attributes :id, :event_id, :initiated_by_id, :attendee_reason, :status,
               :total_payments_count, :resolved_payments_count, :failed_payments_count,
               :initiated_at, :refunds_started_at, :completed_at, :created_at, :updated_at
  end
end
