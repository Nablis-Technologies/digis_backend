# frozen_string_literal: true

module Finance
  # Closes an event only after every materialized date is completed or
  # cancelled. The event lock makes completion the authoritative maturity
  # boundary; payout allocation still rechecks the same facts later.
  class CompleteEvent < Core::BaseService
    SCHEDULER_SOURCE = "scheduler"

    def initialize(event:, actor:, idempotency_key:, at: Time.current, source: "manual")
      @event_id = event.id
      @actor = actor
      @idempotency_key = idempotency_key
      @at = at.to_time.utc
      @source = source.to_s
    end

    def call
      key = Core::IdempotencyKey.new(idempotency_key)
      audit_key = "finance-event-completed-#{key.digest}"
      completed = false
      outcome = nil
      completed_event = nil

      Events::Event.transaction do
        completed_event = Events::Event.lock.find(event_id)
        unless authorized?(completed_event)
          outcome = failure(finance_error(:event_completion_unauthorized, code: "unauthorized", status: :forbidden))
          next
        end

        existing = Core::AuditLog.find_by(audit_key:)
        if existing
          outcome = if replay_audit?(existing, completed_event, key)
            success(completed_event)
          else
            failure(finance_error(:idempotency_conflict, code: "idempotency_conflict"))
          end
          next
        end

        if completed_event.status == "completed"
          outcome = failure(finance_error(:event_already_completed, code: "event_already_completed"))
          next
        end
        unless completed_event.status == "published"
          outcome = failure(finance_error(:event_not_completable, code: "event_not_completable"))
          next
        end

        dates = completed_event.event_dates.order(:id).lock.to_a
        changed_dates = complete_ended_dates(event: completed_event, dates:, key:)
        completed_event.update!(schedule_version: completed_event.schedule_version + 1) if changed_dates.any?
        unless dates.present? && dates.all? { |date| date.status.in?(%w[completed cancelled]) }
          outcome = failure(finance_error(:event_dates_incomplete, code: "event_dates_incomplete"))
          next
        end

        previous_status = completed_event.status
        completed_event.update!(status: "completed", completed_at: at)
        publish_completion!(completed_event)
        completed_event.record_audit!(
          "event.completed",
          audit_key:,
          audited_changes: { status: [ previous_status, "completed" ], completed_at: at.iso8601 },
          metadata: { idempotency_key: key.to_s, source: source },
          actor:
        )
        completed = true
      end

      return outcome if outcome

      MatureEventFundsJob.perform_later(completed_event.id) if completed
      success(completed_event)
    rescue ArgumentError
      failure(finance_error(:idempotency_key_invalid, code: "idempotency_key_invalid"))
    rescue ActiveRecord::RecordNotFound
      failure(finance_error(:source_not_found, code: "source_not_found", status: :not_found))
    rescue ActiveRecord::RecordInvalid => error
      failure(
        Core::BusinessError.new(
          I18n.t("finance.errors.event_completion_invalid"),
          code: "event_completion_invalid", status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      )
    rescue Core::Error => error
      failure(error)
    end

    private

    attr_reader :event_id, :actor, :idempotency_key, :at, :source

    def finance_error(key, code:, status: :unprocessable_entity)
      Core::BusinessError.new(I18n.t("finance.errors.#{key}"), code:, status:)
    end

    def platform_admin?(user)
      user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
    end

    def authorized?(event)
      return true if source == SCHEDULER_SOURCE && actor.nil?

      platform_admin?(actor) || Events::AuthorizationResolver.organization_admin_or_owner?(actor, event)
    end

    def replay_audit?(audit, event, key)
      audit.auditable_type == event.class.name && audit.auditable_id == event.id &&
        audit.action == "event.completed" && audit.metadata["idempotency_key"] == key.to_s &&
        audit.metadata["source"] == source && audit.actor_id == actor&.id
    end

    def complete_ended_dates(event:, dates:, key:)
      dates.each_with_object([]) do |date, changed|
        next unless date.status == "scheduled" && date.ends_at <= at

        date.update!(status: "completed")
        event.record_audit!(
          "event.date.completed",
          audit_key: "finance-event-date-completed-#{date.id}-#{date.ends_at.to_i}",
          audited_changes: { event_date_id: date.id, status: [ "scheduled", "completed" ] },
          metadata: { event_date_id: date.id, idempotency_key: key.to_s, source: source },
          actor:
        )
        changed << date
      end
    end

    def publish_completion!(event)
      result = Core::Outbox::Publish.call(
        topic: "events",
        event_type: "event.completed",
        aggregate: event,
        payload: { event_id: event.id, completed_at: at.iso8601 },
        idempotency_key: "event-completed-#{event.id}"
      )
      raise result.error if result.failure?
    end
  end
end
