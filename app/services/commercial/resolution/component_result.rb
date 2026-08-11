# frozen_string_literal: true

module Commercial
  module Resolution
    # A scalar snapshot of one selected fee component. It intentionally omits
    # Active Record objects, assignment reasons, and negotiation notes so the
    # result can be persisted by Orders as safe immutable commercial evidence.
    class ComponentResult
      ATTRIBUTES = %i[
        component_type label currency amount_minor signed_amount_minor
        schedule_id schedule_code schedule_type version_id version_number definition_digest
        assignment_id program_id component_id calculation_type basis_type basis_minor rate_bps
        fixed_amount_minor minimum_minor maximum_minor tier_position tier_metric_type
        tier_metric_value tier_window_type tier_starts_at_value payer default_payer funder refund_policy
        offset_component_type scope explanation
      ].freeze

      attr_reader(*ATTRIBUTES)

      def initialize(attributes = nil, **keyword_attributes)
        attributes = (attributes || {}).to_h.merge(keyword_attributes).transform_keys(&:to_sym)
        @attributes = deep_freeze(ATTRIBUTES.index_with { |attribute| attributes[attribute] })
        ATTRIBUTES.each { |attribute| instance_variable_set("@#{attribute}", @attributes[attribute]) }
        freeze
      end

      def fee_schedule_id = schedule_id

      def fee_schedule_version_id = version_id

      def fee_component_id = component_id

      def charged_to = payer

      def source_type = explanation[:source]

      def window_type = tier_window_type

      def to_h
        @attributes
      end

      def as_json(*)
        to_h
      end

      private

      def deep_freeze(value)
        case value
        when Hash
          value.each { |key, child| deep_freeze(key); deep_freeze(child) }
        when Array
          value.each { |child| deep_freeze(child) }
        end
        value.freeze
      end
    end
  end
end
