# frozen_string_literal: true

require "digest"
require "json"

module Commercial
  module Alerts
    # Publishes one safe, deduplicated operational observation through the
    # existing synchronous audit/outbox boundary. The aggregate is never
    # changed; the digest is the durable replay key for an identical alert.
    class Publish < Core::BaseService
      include Commercial::Governance::CommandSupport

      ACTION = "commercial.operational_alert"
      EVENT_TYPE = ACTION

      def initialize(kind:, aggregate:, details:, state: "open")
        @kind = kind.to_s
        @aggregate = aggregate
        @details = details.to_h.deep_stringify_keys
        @state = state.to_s
      end

      def call
        return failure(invalid_alert_error) unless valid_input?

        fingerprint = fingerprint_for(
          kind:,
          state:,
          aggregate_type: aggregate.class.base_class.name,
          aggregate_id: aggregate.id,
          details:
        )
        transition_key = "commercial-operational-alert-#{fingerprint}"
        record_transition!(
          target: aggregate,
          actor: nil,
          audit_key: transition_key,
          action: ACTION,
          audited_changes: { "kind" => kind, "state" => state },
          metadata: {
            "kind" => kind, "state" => state, "evidence_digest" => fingerprint, "details" => details
          },
          topic: "commercial",
          event_type: EVENT_TYPE,
          payload: {
            kind:, state:, evidence_digest: fingerprint,
            aggregate_id: aggregate.id, details:
          },
          outbox_key: transition_key
        ).then { |event| success(event) }
      rescue Core::Error => error
        failure(error)
      rescue ArgumentError, NoMethodError, TypeError
        failure(invalid_alert_error)
      end

      private

      attr_reader :kind, :aggregate, :details, :state

      def valid_input?
        kind.present? && state.present? && aggregate.respond_to?(:id) && aggregate.id.present? &&
          aggregate.class.respond_to?(:base_class) && details.is_a?(Hash)
      end

      def invalid_alert_error
        Core::BusinessError.new(
          I18n.t("commercial.governance.errors.invalid_operational_alert"),
          code: "invalid_operational_alert", status: :unprocessable_entity
        )
      end
    end
  end
end
