# frozen_string_literal: true

module Events
  class RecurrenceRuleSerializer < ActiveModel::Serializer
    include Core::AttributeVisibilitySerializer

    type :recurrence_rule

    attributes :id, :event_id, :rrule, :timezone, :dtstart_local, :duration_seconds,
               :generated_until, :active, :exdates, :rdates, :created_at, :updated_at
  end
end
