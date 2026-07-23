# frozen_string_literal: true

module Events
  module Recurrence
    # Creates or updates the single recurrence rule for an event and schedules
    # background materialization. Persisting the rule and enqueuing the job are
    # kept inside a transaction; the job itself performs the date expansion
    # after commit so no external work happens in the transaction.
    class Configure < Core::BaseService
      def initialize(event:, actor:, attributes:)
        @event = event
        @actor = actor
        @attributes = attributes
      end

      def call
        rule = ActiveRecord::Base.transaction do
          candidate = @event.recurrence_rule || @event.build_recurrence_rule
          candidate.assign_attributes(@attributes)
          candidate.save!
          candidate
        end

        Events::MaterializeRecurrenceJob.perform_later(rule.id)
        record_audit(rule)
        success(rule)
      rescue ActiveRecord::RecordInvalid => e
        failure Core::BusinessError.new(
          I18n.t("events.recurrence.configure.errors.invalid"),
          code: "invalid",
          status: :unprocessable_entity,
          errors: e.record.errors.to_hash
        )
      end

      private

      def record_audit(rule)
        fingerprint = Digest::SHA256.hexdigest(@attributes.to_s)[0, 12]
        Core::Audit::Record.call(
          audit_key: "event-recurrence-configured-#{rule.id}-#{fingerprint}",
          action: "event.recurrence.configured",
          auditable_type: "Events::RecurrenceRule",
          auditable_id: rule.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          audited_changes: rule.attributes,
          metadata: { event_id: @event.id }
        )
      end

      attr_reader :event, :actor, :attributes
    end
  end
end
