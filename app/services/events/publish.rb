# frozen_string_literal: true

module Events
  # Publishes an event exactly once. Locks the event and its organization,
  # rechecks organization verification under lock, gates on readiness, flips
  # status once, writes durable audit + outbox evidence, and schedules
  # discovery refresh after commit. Idempotent for a repeated idempotency key.
  class Publish < Core::BaseService
    def initialize(event:, actor:, idempotency_key:)
      @event = event
      @actor = actor
      @idempotency_key = idempotency_key
    end

    def call
      return success(event) if event.published?

      Events::Event.transaction do
        event.lock!
        event.organization.lock!

        readiness = PublicationReadiness.call(event:)
        return readiness if readiness.failure?

        event.update!(status: "published", published_at: Time.current)

        Core::Outbox::Publish.call(
          topic: "events",
          event_type: "event.published",
          aggregate: event,
          payload: { event_id: event.id },
          idempotency_key: "event-published-#{event.id}"
        )

        event.record_audit!(
          "event.published",
          audited_changes: { status: [ "draft", "published" ] },
          metadata: { idempotency_key: @idempotency_key },
          actor: @actor
        )
      end

      success(event)
    rescue ActiveRecord::RecordInvalid => error
      failure Core::BusinessError.new(
        I18n.t("events.publish.errors.invalid_event"),
        code: "invalid_event",
        status: :unprocessable_entity,
        errors: error.record.errors.to_hash
      )
    end

    private

    attr_reader :event, :actor, :idempotency_key
  end
end
