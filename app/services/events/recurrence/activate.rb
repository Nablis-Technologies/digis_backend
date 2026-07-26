# frozen_string_literal: true

module Events
  module Recurrence
    # Activates the recurrence rule, flipping the operational on/off switch so the
    # event's recurring dates are materialized and kept in sync. Idempotent and
    # audited.
    class Activate < Core::BaseService
      def initialize(rule:, actor:)
        @rule = rule
        @actor = actor
      end

      def call
        return success(rule) if rule.active?

        ActiveRecord::Base.transaction do
          rule.update!(active: true)
          record_audit
          success(rule)
        end
      rescue ActiveRecord::RecordInvalid => error
        failure Core::BusinessError.new(
          I18n.t("events.recurrence.errors.activate"),
          code: "invalid_recurrence_rule",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      end

      private

      attr_reader :rule, :actor

      def record_audit
        Core::Audit::Record.call(
          audit_key: "event-recurrence-activate-#{rule.id}",
          action: "event.recurrence.activated",
          auditable_type: "Events::RecurrenceRule",
          auditable_id: rule.id,
          actor_type: actor.class.name,
          actor_id: actor.id,
          audited_changes: { active: [ false, true ] },
          metadata: { event_id: rule.event_id }
        )
      end
    end
  end
end
