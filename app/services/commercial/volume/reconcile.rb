# frozen_string_literal: true

module Commercial
  module Volume
    # Repairs a prospective counter from immutable usage evidence. A repair is
    # the only operation allowed to lower a cache; accepted-order recording
    # remains monotonic and never rewrites retained activity.
    class Reconcile < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(counter:)
        @counter = counter
      end

      def call
        ActiveRecord::Base.transaction do
          counter = lock_counter
          return failure(volume_error(:record_not_found)) unless counter

          usage_value = VolumeUsage.for_dimension(counter.attributes.symbolize_keys).sum(:value)
          return success(counter) if usage_value == counter.value

          before = counter.value
          counter.update!(value: usage_value)
          record_reconciliation!(counter, before, usage_value)
          success(counter)
        end
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("commercial.governance.errors.invalid_record"),
            code: "invalid_record", status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      end

      private

      attr_reader :counter

      def lock_counter
        id = counter.respond_to?(:id) ? counter.id : counter
        VolumeCounter.lock.find_by(id:)
      end

      def record_reconciliation!(counter, before, after)
        request_fingerprint = fingerprint_for(
          action: "reconcile", counter_id: counter.id,
          before:, after:, metric_type: counter.metric_type,
          window_type: counter.window_type, window_start_at: counter.window_start_at,
          window_end_at: counter.window_end_at, currency: counter.currency
        )
        record_transition!(
          target: counter,
          actor: nil,
          audit_key: "commercial-volume-counter-reconcile-#{counter.id}-#{counter.lock_version}",
          action: "commercial.volume_counter.reconciled",
          audited_changes: { "value" => [ before, after ] },
          metadata: {
            "request_fingerprint" => request_fingerprint,
            "metric_type" => counter.metric_type,
            "window_type" => counter.window_type
          },
          topic: "commercial",
          event_type: "commercial.volume_counter.reconciled",
          payload: {
            volume_counter_id: counter.id,
            fee_component_id: counter.fee_component_id,
            organization_id: counter.organization_id,
            value: after
          }
        )
      end

      def volume_error(key)
        Core::BusinessError.new(
          I18n.t("commercial.volume.errors.#{key}"),
          code: key.to_s, status: :unprocessable_entity
        )
      end
    end
  end
end
