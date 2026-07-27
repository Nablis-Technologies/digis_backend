# frozen_string_literal: true

module Events
  module Recurrence
    # Deactivates the recurrence rule, flipping the operational on/off switch so
    # the event stops generating new recurring dates while preserving the rule,
    # its generated dates, and the audit trail. Idempotent and audited.
    class Deactivate < Core::BaseService
      def initialize(rule:, actor:)
        @rule = rule
        @actor = actor
      end

      def call
        return success(rule) unless rule.active?

        ActiveRecord::Base.transaction do
          rule.update!(active: false)
          record_audit
          success(rule)
        end
      rescue ActiveRecord::RecordInvalid => error
        failure Core::BusinessError.new(
          I18n.t("events.recurrence.errors.deactivate"),
          code: "invalid_recurrence_rule",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      end

      private

      attr_reader :rule, :actor

      def record_audit
        Core::Audit::Record.call(
          audit_key: "event-recurrence-deactivate-#{rule.id}-#{Time.current.to_f}",
          action: "event.recurrence.deactivated",
          auditable_type: "Events::RecurrenceRule",
          auditable_id: rule.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: { active: [ true, false ] },
          metadata: { event_id: rule.event_id }
        )
      end
    end
  end
end
