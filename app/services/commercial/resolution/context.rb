# frozen_string_literal: true

module Commercial
  module Resolution
    # Immutable, server-owned facts used to resolve one quote. The explicit
    # attribute allowlist is the trust boundary: callers cannot smuggle an
    # arbitrary expression or basis value into commercial calculations.
    class Context
      ATTRIBUTES = %i[
        organization_id event_id event_product_id product_type sale_context provider payment_method
        sales_channel currency settlement_currency quoted_at item_face_value_minor
        item_net_value_after_organizer_promotion_minor eligible_order_subtotal_minor
        resale_acquisition_amount_minor accepted_paid_units accepted_gross_minor
        organizer_payer_selections
      ].freeze

      BASIS_ATTRIBUTES = {
        item_face_value: :item_face_value_minor,
        item_net_value_after_organizer_promotion: :item_net_value_after_organizer_promotion_minor,
        eligible_order_subtotal: :eligible_order_subtotal_minor,
        resale_acquisition_amount: :resale_acquisition_amount_minor,
        accepted_paid_units: :accepted_paid_units,
        accepted_gross: :accepted_gross_minor
      }.freeze

      CODE_ATTRIBUTES = %i[
        product_type sale_context provider payment_method sales_channel currency settlement_currency
      ].freeze
      CURRENCY_ATTRIBUTES = %i[currency settlement_currency].freeze
      INTEGER_ATTRIBUTES = %i[
        item_face_value_minor item_net_value_after_organizer_promotion_minor eligible_order_subtotal_minor
        resale_acquisition_amount_minor accepted_paid_units accepted_gross_minor
      ].freeze
      PAYER_COMPONENT_TYPES = Commercial::FeeComponent::COMPONENT_TYPES.freeze
      PAYER_VALUES = %w[buyer organizer].freeze

      attr_reader(*ATTRIBUTES)

      def initialize(attributes = nil, **keyword_attributes)
        attributes = normalize_attributes(attributes, keyword_attributes)
        validate_keys!(attributes)

        ATTRIBUTES.each do |attribute|
          instance_variable_set("@#{attribute}", normalize(attribute, attributes[attribute]))
        end
        @organizer_payer_selections = deep_freeze(@organizer_payer_selections)
        @to_h = deep_freeze(ATTRIBUTES.index_with { |attribute| public_send(attribute) })
        freeze
      end

      def basis_value(basis_type)
        attribute = BASIS_ATTRIBUTES[basis_type.to_s.to_sym]
        return public_send(attribute) if attribute

        raise ArgumentError, I18n.t("commercial.resolution.errors.invalid_context_value")
      end

      def metric_value(metric_type)
        basis_value(metric_type)
      end

      def to_h
        @to_h
      end

      private

      def normalize_attributes(attributes, keyword_attributes)
        positional = attributes.to_h
        positional.merge(keyword_attributes).transform_keys(&:to_sym)
      rescue NoMethodError
        raise ArgumentError, I18n.t("commercial.resolution.errors.invalid_context_value")
      end

      def validate_keys!(attributes)
        unknown = attributes.keys - ATTRIBUTES
        return if unknown.empty?

        raise ArgumentError, I18n.t(
          "commercial.resolution.errors.unknown_context_keys", keys: unknown.sort.join(", ")
        )
      end

      def normalize(attribute, value)
        return normalize_codes(attribute, value) if CODE_ATTRIBUTES.include?(attribute)
        return normalize_integer(attribute, value) if INTEGER_ATTRIBUTES.include?(attribute)
        return normalize_time(value) if attribute == :quoted_at
        return normalize_payer_selections(value) if attribute == :organizer_payer_selections

        value
      end

      def normalize_codes(attribute, value)
        return if value.blank?

        value = value.to_s.strip
        CURRENCY_ATTRIBUTES.include?(attribute) ? value.upcase.presence : value.downcase.presence
      end

      def normalize_integer(attribute, value)
        return if value.nil?
        return value if value.is_a?(Integer) && value >= 0

        raise ArgumentError, I18n.t(
          "commercial.resolution.errors.invalid_context_value", attribute: attribute
        )
      end

      def normalize_time(value)
        return if value.nil?
        return value.to_time.utc.freeze if value.respond_to?(:to_time) && !value.is_a?(String)
        if value.is_a?(String)
          parsed = Time.zone.parse(value) rescue nil
          return parsed.utc.freeze if parsed
        end

        raise ArgumentError, I18n.t("commercial.resolution.errors.invalid_context_value", attribute: :quoted_at)
      end

      def normalize_payer_selections(value)
        return {} if value.nil?
        return normalize_payer_hash(value) if value.is_a?(Hash)

        raise ArgumentError, I18n.t(
          "commercial.resolution.errors.invalid_context_value", attribute: :organizer_payer_selections
        )
      end

      def normalize_payer_hash(value)
        value.to_h.to_h do |component_type, payer|
          component_type = component_type.to_s
          unless PAYER_COMPONENT_TYPES.include?(component_type)
            raise ArgumentError, I18n.t(
              "commercial.resolution.errors.invalid_context_value", attribute: :organizer_payer_selections
            )
          end

          payer = payer.to_s
          unless PAYER_VALUES.include?(payer)
            raise ArgumentError, I18n.t(
              "commercial.resolution.errors.invalid_context_value", attribute: :organizer_payer_selections
            )
          end

          [ component_type.to_s, payer ]
        end
      end

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
