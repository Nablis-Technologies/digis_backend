# frozen_string_literal: true

module Commercial
  module Volume
    # Records accepted-order activity for every tiered commercial component.
    # Usage rows are append-only truth; counters are locked caches that are
    # incremented only after a new usage row is inserted. A unique usage
    # dimension makes payment callbacks safely replayable without inventing a
    # second idempotency protocol for accepted orders.
    class RecordAcceptedOrder < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(order:, component_results: nil, charge_result: nil,
        accepted_paid_units: nil, accepted_gross_minor: nil, accepted_at: Time.current)
        @order = order
        @component_results = component_results || charge_result&.component_results
        @accepted_paid_units = accepted_paid_units
        @accepted_gross_minor = accepted_gross_minor
        @accepted_at = accepted_at
      end

      def call
        return failure(volume_error(:invalid_order)) unless order_id
        return failure(volume_error(:invalid_timestamp)) unless accepted_at.respond_to?(:to_time)

        ActiveRecord::Base.transaction do
          accepted_order = load_order
          return failure(volume_error(:invalid_order)) unless accepted_order&.paid?

          usages = Array(component_results).filter_map do |component_result|
            record_component(accepted_order, component_result)
          end
          success(usages)
        end
      rescue VolumeCommandFailure => error
        failure(error.business_error)
      rescue Core::Error => error
        failure(error)
      rescue ActiveRecord::RecordInvalid => error
        failure(
          Core::BusinessError.new(
            I18n.t("commercial.governance.errors.invalid_record"),
            code: "invalid_record", status: :unprocessable_entity,
            errors: error.record.errors.to_hash
          )
        )
      rescue ArgumentError
        failure(volume_error(:invalid_value))
      end

      private

      attr_reader :order, :component_results, :accepted_paid_units, :accepted_gross_minor, :accepted_at

      def order_id
        order.respond_to?(:id) ? order.id : order.presence
      end

      def load_order
        Orders::Order.includes(event: :event_dates).lock.find_by(id: order_id)
      end

      def record_component(accepted_order, component_result)
        return unless component_result.calculation_type == "tiered"

        component = Commercial::FeeComponent.includes(:fee_tiers, :fee_schedule_version).find_by(
          id: component_result.component_id
        )
        return failure_value(:invalid_component) unless component&.calculation_type == "tiered"

        metric_type = component_result.tier_metric_type
        window_type = component_result.tier_window_type
        return failure_value(:invalid_metric) unless VolumeCounter::METRIC_TYPES.include?(metric_type)
        return failure_value(:invalid_window) unless VolumeCounter::WINDOW_TYPES.include?(window_type)
        return failure_value(:invalid_metric) unless component.fee_tiers.all? { |tier| tier.metric_type == metric_type }
        return failure_value(:invalid_window) unless component.fee_tiers.all? { |tier| tier.window_type == window_type }

        value = accepted_value(metric_type, accepted_order)
        return failure_value(:invalid_value) unless valid_value?(value)

        dimension = build_dimension(accepted_order, component, component_result,
          metric_type:, window_type:)
        return dimension if dimension.is_a?(Core::BaseService::Result)

        counter = lock_counter(dimension)
        usage = existing_usage(dimension, accepted_order.id)
        return usage if usage && usage.value == value
        return failure_value(:usage_conflict) if usage

        usage = insert_usage(dimension, accepted_order, value)
        counter.update!(value: counter.value + value)
        record_usage_transition!(usage, value)
        usage
      end

      def accepted_value(metric_type, accepted_order)
        case metric_type
        when "accepted_paid_units"
          accepted_paid_units.nil? ? Orders::OrderItem.where(order_id: accepted_order.id).sum(:quantity) : accepted_paid_units
        when "accepted_gross"
          accepted_gross_minor.nil? ? accepted_order.settlement_total_minor : accepted_gross_minor
        end
      end

      def valid_value?(value)
        value.is_a?(Integer) && value >= 0
      end

      def build_dimension(accepted_order, component, component_result, metric_type:, window_type:)
        organization_id = component_result.volume_organization_id ||
          Events::Event.where(id: accepted_order.event_id).pick(:organization_id)
        return failure_value(:invalid_component) if organization_id.blank?

        currency = metric_type == "accepted_gross" ?
          (component_result.volume_currency.presence || accepted_order.settlement_currency) : nil
        if metric_type == "accepted_gross" && currency != accepted_order.settlement_currency
          return failure_value(:currency_mismatch)
        end
        return failure_value(:currency_mismatch) if metric_type == "accepted_paid_units" && component_result.volume_currency.present?

        event_id = component_result.volume_event_id
        event_id = accepted_order.event_id if window_type == "event" && event_id.blank?
        return failure_value(:order_event_mismatch) if event_id.present? && event_id != accepted_order.event_id

        window_start_at = component_result.volume_window_start_at
        window_end_at = component_result.volume_window_end_at
        if window_start_at.blank?
          assignment = Commercial::Assignment.find_by(id: component_result.assignment_id)
          window = Window.resolve(
            window_type:, quoted_at: accepted_at,
            event: accepted_order.event, event_id: accepted_order.event_id,
            assignment:, version: component.fee_schedule_version, currency:
          )
          event_id = window.event_id
          window_start_at = window.start_at
          window_end_at = window.end_at
        end

        {
          fee_component_id: component.id,
          organization_id:,
          event_id:,
          metric_type:,
          window_type:,
          window_start_at: window_start_at.to_time.utc,
          window_end_at: window_end_at&.to_time&.utc,
          currency:
        }
      rescue ArgumentError
        failure_value(:invalid_timestamp)
      end

      def lock_counter(dimension)
        Commercial::VolumeCounter.insert_all(
          [ dimension.merge(id: SecureRandom.uuid, value: 0, lock_version: 0,
                            created_at: Time.current, updated_at: Time.current) ],
          unique_by: :idx_volume_counters_on_dimension
        )
        Commercial::VolumeCounter.lock.find_by!(dimension)
      end

      def existing_usage(dimension, accepted_order_id)
        Commercial::VolumeUsage.lock.find_by(dimension.merge(order_id: accepted_order_id))
      end

      def insert_usage(dimension, accepted_order, value)
        attributes = dimension.merge(
          id: SecureRandom.uuid,
          order_id: accepted_order.id,
          value:,
          accepted_at: accepted_at.to_time.utc,
          created_at: Time.current,
          updated_at: Time.current
        )
        Commercial::VolumeUsage.insert_all(
          [ attributes ], unique_by: :idx_volume_usages_on_order_dimension
        )
        Commercial::VolumeUsage.lock.find_by!(dimension.merge(order_id: accepted_order.id))
      end

      def record_usage_transition!(usage, value)
        audit_key = "commercial-volume-usage-#{usage.id}"
        request_fingerprint = fingerprint_for(
          action: "record_accepted_order", usage_id: usage.id,
          order_id: usage.order_id, fee_component_id: usage.fee_component_id,
          metric_type: usage.metric_type, window_type: usage.window_type,
          value:, accepted_at: usage.accepted_at
        )
        record_transition!(
          target: usage,
          actor: nil,
          audit_key:,
          action: "commercial.volume_usage.recorded",
          audited_changes: { "value" => [ nil, value ], "status" => [ nil, "accepted" ] },
          metadata: {
            "request_fingerprint" => request_fingerprint,
            "metric_type" => usage.metric_type,
            "window_type" => usage.window_type
          },
          topic: "commercial",
          event_type: "commercial.volume_usage.recorded",
          payload: {
            volume_usage_id: usage.id,
            order_id: usage.order_id,
            fee_component_id: usage.fee_component_id,
            metric_type: usage.metric_type,
            window_type: usage.window_type,
            value:
          }
        )
      end

      def volume_error(key)
        Core::BusinessError.new(
          I18n.t("commercial.volume.errors.#{key}"),
          code: key.to_s, status: :unprocessable_entity
        )
      end

      def failure_value(key)
        raise VolumeCommandFailure, volume_error(key)
      end

      class VolumeCommandFailure < Core::Error
        attr_reader :business_error

        def initialize(business_error)
          @business_error = business_error
          super(business_error.message)
        end
      end
    end
  end
end
