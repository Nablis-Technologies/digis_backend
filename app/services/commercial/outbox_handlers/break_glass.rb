# frozen_string_literal: true

module Commercial
  module OutboxHandlers
    # Acknowledges an authorized break-glass transition after its synchronous
    # audit has committed. The notification is an integration seam for a
    # security sink; no reason or sensitive payload data is written to logs.
    class BreakGlass < Core::BaseService
      EVENT_TYPE = "commercial.security.break_glass".freeze
      TARGET_KEYS = {
        "Commercial::Assignment" => "assignment_id",
        "Commercial::FeeScheduleVersion" => "fee_schedule_version_id"
      }.freeze

      def initialize(event:)
        @event = event
      end

      def call
        return failure(invalid_event) unless valid_event?

        ActiveSupport::Notifications.instrument(EVENT_TYPE, notification_payload) { }
        Rails.logger.warn(log_message)
        success(@event)
      end

      private

      attr_reader :event

      def valid_event?
        event.topic.to_s == "security" &&
          event.event_type == EVENT_TYPE &&
          payload.is_a?(Hash) &&
          payload["operation"].present? &&
          target_key.present? &&
          payload[target_key].present?
      end

      def payload
        @payload ||= event.payload.deep_stringify_keys
      end

      def target_key
        TARGET_KEYS[event.aggregate_type]
      end

      def notification_payload
        {
          event_id: event.id,
          aggregate_type: event.aggregate_type,
          aggregate_id: event.aggregate_id,
          operation: payload.fetch("operation")
        }
      end

      def log_message
        "Commercial break-glass security event acknowledged " \
          "event_id=#{event.id} aggregate_type=#{event.aggregate_type} " \
          "aggregate_id=#{event.aggregate_id} operation=#{payload.fetch("operation")}"
      end

      def invalid_event
        Core::BusinessError.new(
          I18n.t("commercial.governance.errors.invalid_security_event"),
          code: "invalid_security_event", status: :unprocessable_entity
        )
      end
    end
  end
end
