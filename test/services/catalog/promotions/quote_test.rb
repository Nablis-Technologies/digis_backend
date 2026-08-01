# frozen_string_literal: true

require "test_helper"

module Catalog
  module Promotions
    class QuoteTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @product = Catalog::EventProduct.create!(
          event: @event,
          name: "Festival Pass",
          type: "merchandise",
          status: "active",
          inventory_mode: "unlimited"
        )
        @promotion = Catalog::Promotion.create!(
          event: @event,
          name: "Opening discount",
          type: "percentage",
          percentage_basis_points: 1_000,
          currency: "ETB",
          status: "active",
          per_user_limit: 1
        )
        @code = create_code
      end

      test "quotes a percentage discount with promotion and code evidence" do
        result = Quote.call(
          promotion: @promotion,
          code: " opening10 ",
          eligible_product_ids: [ @product.id ],
          eligible_subtotal_minor: 10_000,
          charge_currency: "ETB",
          at: Time.current
        )

        assert result.success?, result.error&.message
        quote = result.value
        assert_equal 1_000, quote.discount_minor
        assert_equal @promotion.id, quote.promotion_id
        assert_equal @code.id, quote.promotion_code_id
        assert_equal 250, quote.code_redemption_limit
        assert_equal true, quote.code_active
        assert_nil quote.exchange_rate_id
      end

      test "caps a percentage discount at the maximum" do
        @promotion.update!(maximum_discount_minor: 500)

        quote = Quote.call(
          promotion: @promotion,
          code: "OPENING10",
          eligible_product_ids: [ @product.id ],
          eligible_subtotal_minor: 10_000,
          charge_currency: "ETB",
          at: Time.current
        ).value

        assert_equal 500, quote.discount_minor
      end

      test "rejects a subtotal below the minimum" do
        @promotion.update!(minimum_subtotal_minor: 20_000)

        result = Quote.call(
          promotion: @promotion,
          code: "OPENING10",
          eligible_product_ids: [ @product.id ],
          eligible_subtotal_minor: 10_000,
          charge_currency: "ETB",
          at: Time.current
        )

        assert result.failure?
        assert_match(/minimum/i, result.error.message)
      end

      test "converts fixed discounts through an exchange rate" do
        fixed = Catalog::Promotion.create!(
          event: @event,
          name: "Fixed discount",
          type: "fixed",
          fixed_amount_minor: 10_000,
          currency: "ETB",
          status: "active",
          per_user_limit: 1
        )
        code = create_code(promotion: fixed, value: "FIXED10")
        rate = Catalog::ExchangeRate.create!(
          from_currency: "ETB", to_currency: "USD", rate: 0.018,
          effective_from: 2.days.ago
        )

        quote = Quote.call(
          promotion: fixed,
          code: code.code,
          eligible_product_ids: [ @product.id ],
          eligible_subtotal_minor: 1_000,
          charge_currency: "USD",
          at: Time.current
        ).value

        assert_equal 180, quote.discount_minor
        assert_equal rate.id, quote.exchange_rate_id
      end

      test "propagates a later FX conversion failure" do
        quote = Quote.new(**quote_arguments.merge(charge_currency: "USD"))
        conversion = Core::BaseService::Result.success(
          Catalog::Pricing::CurrencyConverter::Conversion.new(
            amount_minor: 0,
            from_currency: "ETB",
            to_currency: "USD",
            exchange_rate_id: "missing-rate",
            exchange_rate_value: 0.018
          )
        )

        result = quote.send(:convert_money, 1_000, conversion)

        assert_instance_of Core::BaseService::Result, result
        assert result.failure?
        assert_equal I18n.t("catalog.promotion_quote.errors.invalid_fx_quote"), result.error.message
      end

      test "rejects tampered FX evidence" do
        rate = Catalog::ExchangeRate.create!(
          from_currency: "ETB", to_currency: "USD", rate: 0.018,
          effective_from: 2.days.ago
        )

        result = Quote.call(
          promotion: @promotion,
          code: "OPENING10",
          eligible_product_ids: [ @product.id ],
          eligible_subtotal_minor: 10_000,
          charge_currency: "USD",
          at: Time.current,
          fx_quote: {
            from_currency: "ETB",
            charge_currency: "USD",
            exchange_rate_id: rate.id,
            exchange_rate_value: 99
          }
        )

        assert result.failure?
        assert_equal I18n.t("catalog.promotion_quote.errors.invalid_fx_quote"), result.error.message
      end

      test "rejects an out-of-scope product" do
        scoped = Catalog::Promotion.create!(
          event: @event,
          name: "Scoped discount",
          type: "fixed",
          fixed_amount_minor: 100,
          currency: "ETB",
          status: "active",
          per_user_limit: 1
        )
        Catalog::PromotionProduct.create!(promotion: scoped, event_product: @product)
        other_product = Catalog::EventProduct.create!(
          event: @event,
          name: "Other product",
          type: "merchandise",
          status: "active",
          inventory_mode: "unlimited"
        )
        scoped_code = create_code(promotion: scoped, value: "SCOPED")

        result = Quote.call(
          promotion: scoped,
          code: scoped_code.code,
          eligible_product_ids: [ other_product.id ],
          eligible_subtotal_minor: 1_000,
          charge_currency: "ETB",
          at: Time.current
        )

        assert result.failure?
        assert_match(/scope/i, result.error.message)
      end

      test "rejects inactive or out-of-window codes" do
        @code.update!(active: false)
        inactive = Quote.call(**quote_arguments)
        assert inactive.failure?

        @code.update!(active: true, starts_at: 2.days.from_now)
        future = Quote.call(**quote_arguments)
        assert future.failure?
      end

      test "quote evidence is immutable" do
        quote = Quote.call(**quote_arguments).value

        assert_raises(NoMethodError) { quote.discount_minor = 1 }
      end

      private

      def quote_arguments
        {
          promotion: @promotion,
          code: "OPENING10",
          eligible_product_ids: [ @product.id ],
          eligible_subtotal_minor: 10_000,
          charge_currency: "ETB",
          at: Time.current
        }
      end

      def create_code(promotion: @promotion, value: "OPENING10")
        Catalog::PromotionCode.create!(
          promotion: promotion,
          code: value,
          code_digest: Catalog::PromotionCode.code_digest_for(event_id: @event.id, code: value),
          redemption_limit: 250
        )
      end
    end
  end
end
