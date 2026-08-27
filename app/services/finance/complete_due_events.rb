# frozen_string_literal: true

module Finance
  # Finds a bounded set of published events with ended scheduled dates and
  # delegates each transition to the authoritative completion command.
  class CompleteDueEvents < Core::BaseService
    BATCH_SIZE = 100
    EXPECTED_SKIP_CODES = %w[event_dates_incomplete event_already_completed event_not_completable].freeze

    class SweepFailure < Core::Error
      attr_reader :completed_ids, :failures

      def initialize(completed_ids:, failures:)
        @completed_ids = completed_ids.freeze
        @failures = failures.map(&:freeze).freeze
        super(I18n.t("finance.errors.complete_due_events_failed", count: @failures.length))
      end
    end

    def initialize(at: Time.current)
      @at = at.to_time.utc
    end

    def call
      completed_ids = []
      failures = []
      candidate_events.each do |event|
        result = complete_event(event)
        if result.failure?
          next if EXPECTED_SKIP_CODES.include?(result.error.code)

          failures << { event_id: event.id, code: result.error.code }
          next
        end

        completed_ids << event.id
      end

      report_failures(failures)
      raise SweepFailure.new(completed_ids:, failures:) if failures.any?

      success(completed_ids)
    end

    private

    attr_reader :at

    def candidate_event_ids
      Events::Event
        .where(status: "published")
        .joins(:event_dates)
        .where(events_event_dates: { status: "scheduled" })
        .where("events_event_dates.ends_at <= ?", at)
        .distinct
        .order(:id)
        .limit(BATCH_SIZE)
        .pluck(:id)
    end

    def candidate_events
      ids = candidate_event_ids
      return [] if ids.empty?

      Events::Event.where(id: ids).order(:id).to_a
    end

    def complete_event(event)
      Finance::CompleteEvent.call(
        event:, actor: nil,
        source: Finance::CompleteEvent::SCHEDULER_SOURCE,
        idempotency_key: "finance-event-auto-complete-#{event.id}", at:
      )
    end

    def report_failures(failures)
      return if failures.empty?

      Rails.logger.error(
        "Finance due-event completion sweep failed " \
        "events=#{failures.map { |failure| failure[:event_id] }.join(",")} " \
        "codes=#{failures.map { |failure| failure[:code] }.join(",")}"
      )
    end
  end
end
