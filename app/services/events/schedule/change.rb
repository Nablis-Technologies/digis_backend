# frozen_string_literal: true

module Events
  module Schedule
    # Applies an append-only schedule change to an event's dates. Under a single
    # event lock it bumps the schedule version once, writes an immutable
    # old/new snapshot per changed date, updates the dates in place (their ids
    # never change), and records durable audit + outbox evidence. The whole
    # command is idempotent for a repeated idempotency key: a replay is
    # short-circuited before any mutation, so version and history stay stable.
    class Change < Core::BaseService
      def initialize(event:, actor:, changes:, idempotency_key:)
        @event = event
        @actor = actor
        @changes = changes
        @idempotency_key = idempotency_key
      end

      def call
        entries = normalized_changes
        return failure(empty_failure) if entries.empty?

        missing = entries.keys - event.event_dates.where(id: entries.keys).pluck(:id)
        return failure(invalid_dates_error) unless missing.empty?

        Events::Event.transaction do
          event.lock!

          # Idempotency guard: the outbox key is unique per (event, key), so if
          # it already exists this is a replay — leave version and history alone.
          return success(existing_changes) if Core::OutboxEvent.exists?(idempotency_key: outbox_key)

          date_changes = apply_changes(entries)
          event.update!(version: event.version + 1, schedule_version: event.schedule_version + 1)

          record_audit(date_changes)
          publish_outbox(date_changes)

          @result = date_changes
        end

        Events::ScheduleChangedNotificationsJob.perform_later(event.id)
        success(@result)
      rescue ActiveRecord::RecordInvalid => error
        failure Core::BusinessError.new(
          I18n.t("events.schedule_change.errors.invalid"),
          code: "invalid",
          status: :unprocessable_entity,
          errors: error.record.errors.to_hash
        )
      end

      private

      attr_reader :event, :actor, :changes, :idempotency_key

      # Lock and process dates in a deterministic id order so concurrent changes
      # never deadlock and history is written predictably.
      def apply_changes(entries)
        dates = event.event_dates
                     .where(id: entries.keys)
                     .order(:id)
                     .lock
                     .index_by(&:id)

        entries.keys.sort.map do |date_id|
          date = dates.fetch(date_id)
          attributes = entries.fetch(date_id)
          snapshot = build_snapshot(date, attributes)
          date.update!(starts_at: attributes[:new_start_at], ends_at: attributes[:new_end_at])
          snapshot.save!
          snapshot
        end
      end

      def build_snapshot(date, attributes)
        Events::EventDateChange.new(
          event: event,
          event_date: date,
          change_type: attributes[:change_type].presence || "reschedule",
          old_start_at: date.starts_at,
          old_end_at: date.ends_at,
          new_start_at: attributes[:new_start_at],
          new_end_at: attributes[:new_end_at],
          scheduled_by: actor
        )
      end

      def record_audit(date_changes)
        event.record_audit!(
          "event.schedule.changed",
          audit_key: audit_key,
          audited_changes: { version: [ event.version - 1, event.version ] },
          metadata: { event_date_ids: date_changes.map(&:event_date_id), idempotency_key: idempotency_key },
          actor: actor
        )
      end

      def publish_outbox(date_changes)
        Core::Outbox::Publish.call(
          topic: "events",
          event_type: "events.schedule_changed",
          aggregate: event,
          payload: {
            event_id: event.id,
            version: event.version,
            event_date_ids: date_changes.map(&:event_date_id)
          },
          idempotency_key: outbox_key
        )
      end

      def existing_changes
        Events::EventDateChange.where(event: event, event_date_id: normalized_changes.keys)
      end

      def outbox_key
        "event-schedule-changed-#{event.id}-#{idempotency_key}"
      end

      def audit_key
        "event-schedule-changed-#{event.id}-#{idempotency_key}"
      end

      def empty_failure
        Core::BusinessError.new(
          I18n.t("events.schedule_change.errors.no_changes"),
          code: "no_changes",
          status: :unprocessable_entity
        )
      end

      def invalid_dates_error
        Core::BusinessError.new(
          I18n.t("events.schedule_change.errors.invalid_dates"),
          code: "invalid_dates",
          status: :unprocessable_entity
        )
      end

      # Returns a { date_id => attributes } hash keyed on the event_date id.
      def normalized_changes
        @normalized_changes ||= Array(changes).each_with_object({}) do |entry, memo|
          attributes = entry.respond_to?(:to_unsafe_h) ? entry.to_unsafe_h : entry.to_h
          attributes = attributes.symbolize_keys
          date_id = attributes[:event_date_id]
          next if date_id.blank?

          memo[date_id] = attributes.slice(:new_start_at, :new_end_at, :change_type)
        end
      end
    end
  end
end
