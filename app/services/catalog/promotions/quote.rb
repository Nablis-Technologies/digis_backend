# frozen_string_literal: true

module Catalog
  module Promotions
    # Calculates one promotion discount without reserving or counting usage.
    #
    # The result carries the promotion, code, scope, and exchange-rate evidence
    # needed to verify the discount later during checkout. Every threshold and
    # fixed amount uses the same validated FX evidence as the base conversion.
    class Quote < Core::BaseService
      def initialize(promotion:, code:, eligible_product_ids:, eligible_subtotal_minor:,
        charge_currency:, at: nil, fx_quote: nil)
        @promotion = promotion
        @code = code
        @eligible_product_ids = Array(eligible_product_ids).compact.map(&:to_s).uniq.sort
        @eligible_subtotal_minor = eligible_subtotal_minor
        @charge_currency = charge_currency.to_s.upcase
        @at = at || Time.current
        @fx_quote = fx_quote
      end

      def call
        return failure_i18n("catalog.promotion_quote.errors.invalid_promotion") unless @promotion.usable_at?(@at)

        promotion_code = find_code
        return failure_i18n("catalog.promotion_quote.errors.invalid_code") unless promotion_code
        return failure_i18n("catalog.promotion_quote.errors.inactive_code") unless promotion_code.active?
        return failure_i18n("catalog.promotion_quote.errors.code_outside_window") unless promotion_code.usable_at?(@at)
        return failure_i18n("catalog.promotion_quote.errors.invalid_subtotal") unless valid_subtotal?
        return failure_i18n("catalog.promotion_quote.errors.invalid_product_scope") unless valid_product_scope?

        conversion = convert(0)
        return failure(conversion.error) if conversion.failure?

        minimum_result = convert_money(@promotion.minimum_subtotal_minor, conversion)
        return failure(minimum_result.error) if minimum_result.failure?

        minimum = minimum_result.value
        return failure_i18n("catalog.promotion_quote.errors.minimum_not_met") if minimum && @eligible_subtotal_minor < minimum

        discount_result = calculate_discount(conversion)
        return failure(discount_result.error) if discount_result.failure?

        success(build_quote(promotion_code, discount_result.value, conversion))
      end

      private

      # Look up the normalized code by its event-scoped keyed digest; plaintext
      # promotion codes are never queried or stored in the database.
      def find_code
        digest = Catalog::PromotionCode.code_digest_for(
          event_id: @promotion.event_id,
          code: @code
        )
        @promotion.promotion_codes.find_by(code_digest: digest)
      end

      def valid_subtotal?
        @eligible_subtotal_minor.is_a?(Integer) && @eligible_subtotal_minor >= 0
      end

      def valid_product_scope?
        return false if @eligible_product_ids.empty?

        product_ids = Catalog::EventProduct
          .where(event_id: @promotion.event_id, id: @eligible_product_ids)
          .pluck(:id)
          .map(&:to_s)
        return false unless product_ids.sort == @eligible_product_ids

        scoped_ids = @promotion.promotion_products.pluck(:event_product_id).map(&:to_s)
        scoped_ids.empty? || (@eligible_product_ids - scoped_ids).empty?
      end

      def convert(amount_minor)
        Catalog::Pricing::CurrencyConverter.call(
          amount_minor:,
          from_currency: @promotion.currency,
          to_currency: @charge_currency,
          at: @at,
          fx_quote: @fx_quote
        )
      end

      # Convert thresholds and fixed amounts against the same FX evidence so a
      # quote cannot mix rates from different calculations.
      def convert_money(amount_minor, conversion)
        return failure(conversion.error) if conversion.failure?
        return success if amount_minor.nil?
        return success(amount_minor) if @promotion.currency == @charge_currency

        result = Catalog::Pricing::CurrencyConverter.call(
          amount_minor:,
          from_currency: @promotion.currency,
          to_currency: @charge_currency,
          at: @at,
          fx_quote: conversion.value
        )
        return failure(result.error) if result.failure?

        success(result.value.amount_minor)
      end

      def calculate_discount(conversion)
        amount_result = if @promotion.type == "percentage"
          success(
            ((@eligible_subtotal_minor * @promotion.percentage_basis_points).to_d / 10_000)
              .round(0, BigDecimal::ROUND_HALF_UP)
              .to_i
          )
        else
          convert_money(@promotion.fixed_amount_minor, conversion)
        end
        return failure(amount_result.error) if amount_result.failure?

        maximum_result = convert_money(@promotion.maximum_discount_minor, conversion)
        return failure(maximum_result.error) if maximum_result.failure?

        amount = amount_result.value
        maximum = maximum_result.value
        amount = [ amount, maximum ].min if maximum
        success([ amount, @eligible_subtotal_minor ].min)
      end

      def build_quote(promotion_code, discount, conversion)
        Catalog::PromotionQuote.new(
          promotion_id: @promotion.id,
          promotion_code_id: promotion_code.id,
          promotion_version: @promotion.version,
          eligible_product_ids: @eligible_product_ids,
          eligible_subtotal_minor: @eligible_subtotal_minor,
          discount_minor: discount,
          charge_currency: @charge_currency,
          promotion_currency: @promotion.currency,
          calculation_type: @promotion.type,
          percentage_basis_points: @promotion.percentage_basis_points,
          fixed_amount_minor: @promotion.fixed_amount_minor,
          minimum_subtotal_minor: @promotion.minimum_subtotal_minor,
          maximum_discount_minor: @promotion.maximum_discount_minor,
          redemption_limit: @promotion.redemption_limit,
          per_user_limit: @promotion.per_user_limit,
          code_redemption_limit: promotion_code.redemption_limit,
          code_starts_at: promotion_code.starts_at,
          code_ends_at: promotion_code.ends_at,
          code_active: promotion_code.active,
          exchange_rate_id: conversion.value.exchange_rate_id,
          exchange_rate_value: conversion.value.exchange_rate_value,
          at: @at
        )
      end
    end
  end
end
