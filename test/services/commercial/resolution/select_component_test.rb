# frozen_string_literal: true

require "test_helper"

module Commercial
  module Resolution
    class SelectComponentTest < ActiveSupport::TestCase
      include Commercial::FeeDefinitionTestHelpers

      setup do
        @schedule = create_schedule(code: "resolver_scope_schedule")
        @version = create_version(@schedule)
        @product = create_product
      end

      test "ranks product, product type, context, provider, channel, and currency scopes deterministically" do
        general = create_component(@version, label: "general")
        currency = create_component(@version, currency: "ETB", label: "currency")
        channel = create_component(@version, sales_channel: "online", label: "channel")
        provider = create_component(@version, provider: "chapa", label: "provider")
        method = create_component(
          @version, provider: "chapa", payment_method: "card", label: "provider and method"
        )
        sale_context = create_component(@version, sale_context: "primary", label: "sale context")
        product_type = create_component(@version, product_type: "ticket", label: "product type")
        exact_product = create_component(@version, event_product: @product, label: "exact product")

        exact = select([ general, currency, channel, provider, method, sale_context, product_type, exact_product ])
        assert_equal exact_product.id, exact.component.id

        without_product = select(
          [ general, currency, channel, provider, method, sale_context, product_type ],
          event_product_id: nil
        )
        assert_equal product_type.id, without_product.component.id

        without_product_type = select(
          [ general, currency, channel, provider, method, sale_context ],
          event_product_id: nil, product_type: nil
        )
        assert_equal sale_context.id, without_product_type.component.id

        without_sale_context = select(
          [ general, currency, channel, provider, method ],
          event_product_id: nil, product_type: nil, sale_context: nil
        )
        assert_equal method.id, without_sale_context.component.id
      end

      test "fails closed when two candidates have equal precedence and specificity" do
        first = create_component(@version, label: "first")
        second = create_component(@version, label: "second")

        result = Commercial::Resolution::SelectComponent.call(
          component_type: "platform_commission",
          context: context,
          components: [ first, second ]
        )

        assert_predicate result, :failure?
        assert_equal "ambiguous_commercial_terms", result.error.code
      end

      test "does not discard ambiguity for unsaved candidates" do
        first = build_component(@version, label: "first")
        second = build_component(@version, label: "second")

        result = Commercial::Resolution::SelectComponent.call(
          component_type: "platform_commission",
          context: context,
          components: [ first, second ]
        )

        assert_predicate result, :failure?
        assert_equal "ambiguous_commercial_terms", result.error.code
      end

      private

      def select(components, **context_attributes)
        result = Commercial::Resolution::SelectComponent.call(
          component_type: "platform_commission",
          context: context(**context_attributes),
          components: components
        )
        assert_predicate result, :success?, result.error&.message
        result.value
      end

      def context(**attributes)
        Commercial::Resolution::Context.new(
          {
            organization_id: organizations_organizations(:one).id,
            event_id: events_events(:draft_concert).id,
            event_product_id: @product.id,
            product_type: "ticket",
            sale_context: "primary",
            provider: "chapa",
            payment_method: "card",
            sales_channel: "online",
            currency: "ETB",
            quoted_at: Time.utc(2026, 8, 11, 10),
            eligible_order_subtotal_minor: 10_000
          }.merge(attributes)
        )
      end
    end
  end
end
