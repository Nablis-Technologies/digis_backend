# frozen_string_literal: true

module Finance
  # Closes an event only after every materialized date is completed or
  # cancelled. The event lock makes completion the authoritative maturity
  # boundary; payout allocation still rechecks the same facts later.
  class CompleteEvent < Core::BaseService
    def initialize(event:, actor:, idempotency_key:, at: Time.current)
      @event_id = event.id
      @actor = actor
      @idempotency_key = idempotency_key
      @at = at.to_time.utc
    end

    def call
      key = Core::IdempotencyKey.new(idempotency_key).to_s
      audit_key = "finance-event-completed-#{Core::IdempotencyKey.new(key).digest}"
      completed = false

      Events::Event.transaction do
        event = Events::Event.lock.find(event_id)
        unless platform_admin?(actor) || Events::AuthorizationResolver.organization_admin_or_owner?(actor, event)
          return failure(finance_error(:event_completion_unauthorized, code: "unauthorized", status: :forbidden))
        end

        existing = Core::AuditLog.find_by(audit_key:)
        if existing
          return success(event) if replay_audit?(existing, event, key)

          return failure(finance_error(:idempotency_conflict, code: "idempotency_conflict"))
        end

        return failure(finance_error(:event_already_completed, code: "event_already_completed")) if event.status == "completed"
        return failure(finance_error(:event_not_completable, code: "event_not_completable")) unless event.status == "published"

        dates = event.event_dates.order(:id).lock.to_a
        return failure(finance_error(:event_dates_incomplete, code: "event_dates_incomplete")) if dates.empty? || !dates.all? { |date| date.status.in?(%w[completed cancelled]) }

        previous_status = event.status
        event.update!(status: "completed", completed_at: at)
        publish_completion!(event)
        event.record_audit!(
          "event.completed",
          audit_key:,
          audited_changes: { status: [ previous_status, "completed" ], completed_at: at.iso8601 },
          metadata: { idempotency_key: key },
          actor:
        )
        completed = true
        @event = event
      end

      MatureEventFundsJob.perform_later(event.id) if completed
      success(event)
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

    attr_reader :event, :event_id, :actor, :idempotency_key, :at

    def finance_error(key, code:, status: :unprocessable_entity)
      Core::BusinessError.new(I18n.t("finance.errors.#{key}"), code:, status:)
    end

    def platform_admin?(user)
      user&.has_role?("SUPER_ADMIN") || user&.has_role?("ADMIN") || user&.has_role?("CORE_ADMIN")
    end

    def replay_audit?(audit, event, key)
      audit.auditable_type == event.class.name && audit.auditable_id == event.id &&
        audit.action == "event.completed" && audit.metadata["idempotency_key"] == key &&
        audit.actor_id == actor&.id
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
