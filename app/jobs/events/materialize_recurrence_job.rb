# frozen_string_literal: true

module Events
  # Background wrapper that expands a recurrence rule into concrete
  # event_dates rows. Only the rule id is enqueued, never the full rule or
  # its payload.
  class MaterializeRecurrenceJob < ApplicationJob
    queue_as :default
    retry_on StandardError, wait: :polynomially_longer, attempts: 5

    def perform(rule_id)
      rule = Events::RecurrenceRule.find_by(id: rule_id)
      return unless rule

      Events::Recurrence::Materialize.call(rule: rule)
    end
  end
end
