# frozen_string_literal: true

module Commercial
  module Shadow
    # Runs the immutable Commercial resolver against production-shaped
    # contexts without creating orders, payment attempts, or quote state.
    # Resolver failures are reported as safe operational evidence rather than
    # being interpreted as a zero-priced result.
    class Compare < Core::BaseService
      include Commercial::Governance::CommandSupport

      def initialize(proposed_version: nil, contexts: nil, baseline_version: nil, at: Time.current)
        @proposed_version = proposed_version
        @contexts = contexts
        @baseline_version = baseline_version
        @at = at.to_time.utc
      end

      def call
        versions = proposed_versions
        versions.each_with_object([]) do |version, comparisons|
          contexts_for(version).each_with_index do |raw_context, index|
            comparisons << compare_one(version, raw_context, index)
          end
        end.then { |comparisons| success(proposed_versions: versions.map(&:id), comparisons:) }
      rescue Core::Error => error
        failure(error)
      end

      private

      attr_reader :proposed_version, :contexts, :baseline_version, :at

      def proposed_versions
        return [ proposed_version ] if proposed_version

        FeeScheduleVersion.where(status: "scheduled")
          .where("effective_from > ?", at)
          .order(:effective_from, :id).to_a
      end

      def contexts_for(version)
        return Array(contexts) if contexts

        production_contexts(version)
      end

      def production_contexts(_version)
        Orders::Order.where(status: Orders::Order::PAID_STATUSES)
          .includes(:event, :payments, order_items: :event_product)
          .order(created_at: :desc)
          .limit(100)
          .flat_map do |order|
          payment = order.payments.find(&:accepted?)
          order.order_items.map do |item|
            {
              organization_id: order.event.organization_id,
              event_id: order.event_id,
              event_product_id: item.event_product_id,
              product_type: item.type_snapshot,
              sale_context: order.sales_channel == "resale" ? "resale" : "primary",
              provider: payment&.provider,
              payment_method: payment&.payment_method,
              sales_channel: order.sales_channel,
              currency: order.charge_currency,
              settlement_currency: order.settlement_currency,
              quoted_at: order.created_at,
              item_face_value_minor: item.charge_unit_amount_minor * item.quantity,
              item_net_value_after_organizer_promotion_minor: item.total_minor,
              eligible_order_subtotal_minor: order.subtotal_minor - order.discount_minor,
              resale_acquisition_amount_minor: order.sales_channel == "resale" ? item.total_minor : nil,
              accepted_paid_units: item.quantity,
              accepted_gross_minor: order.settlement_total_minor
            }
          end
        end
      end

      def compare_one(version, raw_context, index)
        context = normalize_context(raw_context)
        return gap(version, index, "invalid_context") unless context

        baseline = Commercial::ResolveCharges.call(
          context:, only_version: baseline_version_for(version)
        )
        proposed = Commercial::ResolveCharges.call(context:, only_version: version)
        return resolution_failure(version, index, proposed.error) if proposed.failure?
        return resolution_failure(version, index, baseline.error) if baseline.failure?

        baseline_projection = projection_for(baseline.value)
        proposed_projection = projection_for(proposed.value)
        return match(index, baseline_projection, proposed_projection) if baseline_projection == proposed_projection

        details = {
          context_digest: fingerprint_for(context.to_h),
          baseline: baseline_projection,
          proposed: proposed_projection
        }
        publish_alert(kind: "commercial_shadow_mismatch", aggregate: version, details:)
        { index:, status: "mismatch", details: }
      end

      def normalize_context(raw_context)
        return raw_context if raw_context.is_a?(Commercial::Resolution::Context)

        Commercial::Resolution::Context.new(raw_context)
      rescue ArgumentError, NoMethodError, TypeError
        nil
      end

      def baseline_version_for(version)
        return baseline_version if baseline_version

        FeeScheduleVersion.where(fee_schedule_id: version.fee_schedule_id, status: "active")
          .where("effective_from <= ?", at)
          .where("effective_until IS NULL OR effective_until > ?", at)
          .order(effective_from: :desc, id: :desc).first
      end

      def projection_for(result)
        result.to_h.slice(
          :currency, :settlement_currency, :buyer_fee_total, :organizer_fee_total, :subsidy_total
        ).merge(
          component_results: result.component_results.map do |component|
            component.to_h.slice(:component_type, :currency, :amount_minor, :payer, :funder)
          end
        ).deep_stringify_keys
      end

      def match(index, baseline_projection, proposed_projection)
        { index:, status: "match", baseline: baseline_projection, proposed: proposed_projection }
      end

      def resolution_failure(version, index, error)
        kind = error.code.to_s == "ambiguous_commercial_terms" ? "commercial_resolution_ambiguity" : "commercial_resolution_gap"
        details = { index:, error_code: error.code.to_s, version_id: version.id }
        publish_alert(kind:, aggregate: version, details:)
        { index:, status: kind == "commercial_resolution_ambiguity" ? "ambiguity" : "gap", details: }
      end

      def gap(version, index, code)
        details = { index:, error_code: code, version_id: version.id }
        publish_alert(kind: "commercial_resolution_gap", aggregate: version, details:)
        { index:, status: "gap", details: }
      end

      def publish_alert(kind:, aggregate:, details:)
        result = Commercial::Alerts::Publish.call(kind:, aggregate:, details:)
        raise result.error if result.failure?
      end
    end
  end
end
