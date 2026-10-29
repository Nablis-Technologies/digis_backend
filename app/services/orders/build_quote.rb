# frozen_string_literal: true

require "bigdecimal"

module Orders
  # Builds the short-lived, server-owned checkout envelope. Product pricing,
  # FX, promotions, entitlement reconciliation, and Commercial resolution all
  # happen before an order exists; the resulting immutable evidence is the only
  # pricing input accepted by Orders::CreateCheckout.
  class BuildQuote < Core::BaseService
    HOLD_DURATION = 10.minutes
    MINOR_UNITS = Catalog::Pricing::CurrencyConverter::CURRENCY_MINOR_UNITS

    def initialize(
      event:, items:, charge_currency:, buyer: nil, settlement_currency: nil,
      sales_channel: "online", provider: nil, payment_method: nil,
      organizer_payer_selections: {}, promotion: nil, promotion_code: nil,
      promotion_quote: nil, quoted_at: nil, expires_at: nil,
      require_registrations: true, gift_registration_ids: [], gift_line_ids: []
    )
      @event = event
      @buyer = buyer
      @item_requests = items
      @charge_currency = charge_currency.to_s.upcase
      @settlement_currency = (settlement_currency || event.currency).to_s.upcase
      @sales_channel = sales_channel.to_s.downcase
      @provider = provider
      @payment_method = payment_method
      @organizer_payer_selections = organizer_payer_selections
      @promotion = promotion
      @promotion_code = promotion_code
      @promotion_quote = promotion_quote
      @require_registrations = require_registrations != false
      @gift_registration_ids = Array(gift_registration_ids).map(&:to_s).uniq.freeze
      @gift_line_ids = Array(gift_line_ids).map(&:to_s).uniq.freeze
      @quoted_at = (quoted_at || Time.current).to_time.utc.change(usec: 0)
      @expires_at = (expires_at || @quoted_at + HOLD_DURATION).to_time.utc.change(usec: 0)
    rescue NoMethodError, ArgumentError => error
      @initialization_error = error
    end

    def call
      return failure(checkout_error(:invalid_quote, code: "invalid_quote")) if @initialization_error

      validation = validate_request
      return failure(validation) if validation

      entitlement = Commercial::Entitlements::ReconcileFirstEvent.call(event: @event)
      return failure(entitlement.error) if entitlement.failure?

      lines = build_priced_lines
      return failure(lines) if lines.is_a?(Core::BusinessError)

      promotion_result = build_promotion_quote(lines)
      return failure(promotion_result.error) if promotion_result.failure?

      apply_promotion_discounts(lines, promotion_result.value)
      commercial_results = resolve_commercial(lines)
      return failure(commercial_results.error) if commercial_results.failure?

      build_quote(lines, promotion_result.value, commercial_results.value)
    rescue Core::Error => error
      failure(error)
    rescue ActiveRecord::RecordNotFound
      failure(checkout_error(:product_not_found, code: "product_not_found"))
    end

    private

    attr_reader :event, :buyer, :charge_currency, :settlement_currency, :sales_channel,
                :provider, :payment_method, :organizer_payer_selections, :quoted_at,
                :expires_at

    def validate_request
      return checkout_error(:event_required, code: "event_required") unless event&.id
      return checkout_error(:event_cancelled, code: "event_cancelled", status: :conflict) if event.status == "cancelled"
      return checkout_error(:unsupported_currency, code: "unsupported_currency") unless valid_currency?(charge_currency)
      return checkout_error(:unsupported_currency, code: "unsupported_currency") unless valid_currency?(settlement_currency)
      return checkout_error(:sales_channel_invalid, code: "sales_channel_invalid") unless Orders::Order::SALES_CHANNELS.include?(sales_channel)
      return checkout_error(:quote_expiry_invalid, code: "quote_expiry_invalid") unless expires_at > quoted_at
      return checkout_error(:quote_expiry_invalid, code: "quote_expiry_invalid") if expires_at > quoted_at + HOLD_DURATION
      return checkout_error(:items_required, code: "items_required") if @item_requests.blank?

      nil
    end

    def build_priced_lines
      attributes = Array(@item_requests).map do |request|
        request.respond_to?(:to_h) ? request.to_h.symbolize_keys : {}
      end
      products_by_id = load_products(attributes)
      registrations_by_id = load_registrations(attributes)
      requests = attributes.map do |request|
        normalize_item_request(request, products_by_id:, registrations_by_id:)
      end
      return requests.find { |request| request.is_a?(Core::BusinessError) } if requests.any? { |request| request.is_a?(Core::BusinessError) }
      return checkout_error(:invalid_quote, code: "invalid_quote") unless unique_line_ids?(requests)
      return checkout_error(:duplicate_product, code: "duplicate_product") unless valid_product_line_groups?(requests)
      return checkout_error(:quantity_outside_product_limit, code: "quantity_outside_product_limit") unless
        valid_product_quantity_groups?(requests)

      date_error = Orders::EventDateEligibility.error_for(
        event:,
        event_date_ids: requests.flat_map do |request|
          Array(request[:event_date_ids]) + Array(request[:venue_event_date_ids])
        end,
        at: quoted_at
      )
      return date_error if date_error

      requests.map do |request|
        product = request[:product]
        price_result = Catalog::Pricing::Quote.call(product:, charge_currency:, at: quoted_at)
        return checkout_error(:unsupported_currency, code: "unsupported_currency") if price_result.failure?

        price_quote = price_result.value
        base_amount = base_amount_for(product, price_quote)
        return checkout_error(:price_unavailable, code: "price_unavailable") if base_amount.nil?

        charge_amount = Core::Money.new(amount_minor: price_quote.amount_minor, currency: charge_currency)
        {
          **request,
          price_quote:,
          base_unit_amount_minor: base_amount,
          subtotal_minor: charge_amount.amount_minor * request[:quantity],
          promotion_discount_minor: 0
        }
      end
    end

    def normalize_item_request(attributes, products_by_id:, registrations_by_id:)
      product_value = attributes[:product] || attributes[:product_id]
      product_id = product_value.respond_to?(:id) ? product_value.id : product_value
      product = products_by_id[product_id.to_s]
      return checkout_error(:product_not_found, code: "product_not_found") unless product
      return checkout_error(:product_unavailable, code: "product_unavailable") unless product.status == "active"
      return checkout_error(:product_event_mismatch, code: "product_event_mismatch") unless product.event_id == event.id

      quantity = attributes[:quantity]
      return checkout_error(:quantity_invalid, code: "quantity_invalid") unless quantity.is_a?(Integer) && quantity.positive?

      registration_id = registration_id_for(attributes[:registration] || attributes[:registration_id])
      registration = registrations_by_id[registration_id.to_s]
      if registration
        return checkout_error(:registration_scope_invalid, code: "registration_scope_invalid") unless
          registration_scope_valid?(registration, product)

        payable = gift_registration?(registration) ? registration.status == "gift_pending_claim" : registration.pending_payment?
        return checkout_error(:registration_not_payable, code: "registration_not_payable", status: :conflict) unless payable
      end
      if product.ticket? && registration.nil? && @require_registrations
        return checkout_error(:registration_required, code: "registration_required")
      end

      ticket_type = product.ticket_type
      admissions = if product.ticket?
        registration&.admissions_per_unit_snapshot || ticket_type&.admissions_per_unit
      end
      return checkout_error(:admissions_invalid, code: "admissions_invalid") if product.ticket? && !admissions.to_i.positive?

      event_date_ids, venue_event_date_ids = demand_for_product(attributes, product, registration, quantity, admissions)
      return event_date_ids if event_date_ids.is_a?(Core::BusinessError)
      if product.inventory_mode.in?(%w[per_date event_wide_and_per_date]) && event_date_ids.blank?
        return checkout_error(:event_dates_required, code: "event_dates_required")
      end

      {
        product:,
        product_id: product.id.to_s,
        line_id: attributes[:line_id]&.to_s&.downcase,
        line_key: line_key(product.id, attributes[:line_id]),
        name: product.name,
        type: product.type,
        quantity:,
        registration_id: registration&.id,
        event_date_ids:,
        venue_event_date_ids:,
        admissions_per_unit: admissions
      }
    end

    def unique_line_ids?(requests)
      ids = requests.filter_map { |request| request[:line_id] }
      ids.uniq.length == ids.length
    end

    def valid_product_line_groups?(requests)
      requests.group_by { |request| request[:product_id] }.values.all? do |product_lines|
        product_lines.one? || valid_gift_line_group?(product_lines)
      end
    end

    def valid_gift_line_group?(lines)
      return false unless lines.all? do |line|
        line[:quantity] == 1 && line[:line_id].present? && gift_line?(line)
      end

      registration_ids = lines.filter_map { |line| line[:registration_id]&.to_s }
      registration_ids.empty? || registration_ids.length == lines.length && registration_ids.uniq.length == registration_ids.length
    end

    def valid_product_quantity_groups?(requests)
      requests.group_by { |request| request[:product_id] }.values.all? do |product_lines|
        product = product_lines.first.fetch(:product)
        quantity = product_lines.sum { |line| line.fetch(:quantity) }
        product.min_per_order <= quantity && (product.max_per_order.nil? || quantity <= product.max_per_order)
      end
    end

    def gift_line?(line)
      @gift_line_ids.include?(line[:line_id]) || @gift_registration_ids.include?(line[:registration_id].to_s)
    end

    def line_key(product_id, line_id)
      line_id.present? ? "client:#{line_id.to_s.downcase}" : "product:#{product_id}"
    end

    def demand_for_product(attributes, product, registration, quantity, admissions)
      return non_ticket_demand(attributes) unless product.ticket?

      ticket_type = product.ticket_type
      requested_date_ids = Array(attributes[:event_date_ids]).map(&:to_s).uniq
      selected_date_id = registration&.selected_event_date_id
      if ticket_type.date_selection == "choose_one" && selected_date_id.blank? && requested_date_ids.one?
        selected_date_id = requested_date_ids.sole
      end
      line = Catalog::Inventory::AdmissionLine.call(
        product:, selected_event_date_id: selected_date_id,
        package_quantity: quantity, admissions_per_unit: admissions
      )
      return [ checkout_error(:event_date_unavailable, code: "event_date_unavailable"), [] ] unless line
      return [ checkout_error(:event_date_unavailable, code: "event_date_unavailable"), [] ] if
        requested_date_ids.present? && requested_date_ids.sort != line.event_date_ids

      requested_venue_ids = Array(attributes[:venue_event_date_ids]).map(&:to_s).uniq.sort
      if attributes.key?(:venue_event_date_ids) && requested_venue_ids != line.venue_event_date_ids
        return [ checkout_error(:event_date_unavailable, code: "event_date_unavailable"), [] ]
      end

      [ line.event_date_ids, line.venue_event_date_ids ]
    end

    def non_ticket_demand(attributes)
      event_date_ids = Array(attributes[:event_date_ids]).presence
      venue_event_date_ids = Array(attributes[:venue_event_date_ids]).presence || event_date_ids || []
      [ event_date_ids, venue_event_date_ids ]
    end

    def load_products(requests)
      product_ids = requests.filter_map do |attributes|
        value = attributes[:product] || attributes[:product_id]
        id = value.respond_to?(:id) ? value.id : value
        id.to_s if id.present?
      end.uniq

      Catalog::EventProduct.includes(:prices, :ticket_type, :product_accesses)
        .where(id: product_ids).index_by { |product| product.id.to_s }
    end

    def load_registrations(requests)
      ids = requests.filter_map do |attributes|
        registration_id_for(attributes[:registration] || attributes[:registration_id])&.to_s
      end.uniq
      return {} if ids.empty?

      Ticketing::Registration.where(id: ids).index_by { |registration| registration.id.to_s }
    end

    def registration_id_for(value)
      value.respond_to?(:id) ? value.id : value
    end

    def gift_registration?(registration)
      @gift_registration_ids.include?(registration.id.to_s)
    end

    def registration_scope_valid?(registration, product)
      valid_event_and_product = registration.event_id == event.id &&
        registration.ticket_type_id == product.ticket_type&.id
      return false unless valid_event_and_product

      if gift_registration?(registration)
        buyer.is_a?(Core::User) && registration.status == "gift_pending_claim" && buyer.id != registration.user_id
      else
        !buyer || registration.user_id == buyer.id
      end
    end

    def base_amount_for(product, price_quote)
      return price_quote.amount_minor if price_quote.source_type != "exchange"

      Catalog::ProductPrice.active_at_in_memory(product.prices, at: quoted_at).find do |price|
        price.type == "base" && price.currency == price_quote.from_currency
      end&.amount_minor
    end

    def build_promotion_quote(lines)
      return Core::BaseService::Result.success(@promotion_quote) if @promotion_quote
      return Core::BaseService::Result.success(nil) if @promotion.blank?

      scoped_ids = @promotion.promotion_products.pluck(:event_product_id).map(&:to_s)
      eligible_lines = if scoped_ids.empty?
        lines
      else
        lines.select { |line| scoped_ids.include?(line[:product_id]) }
      end
      return failure(checkout_error(:promotion_unavailable, code: "promotion_unavailable")) if eligible_lines.empty?

      Catalog::Promotions::Quote.call(
        promotion: @promotion,
        code: @promotion_code,
        eligible_product_ids: eligible_lines.map { |line| line[:product_id] }.uniq,
        eligible_subtotal_minor: eligible_lines.sum { |line| line[:subtotal_minor] },
        charge_currency:,
        at: quoted_at
      )
    end

    def apply_promotion_discounts(lines, promotion_quote)
      return unless promotion_quote

      discount_minor = promotion_quote.discount_minor.to_i
      if discount_minor.zero?
        lines.each { |line| line[:promotion_discount_minor] = 0 }
        return
      end

      eligible_ids = promotion_quote.eligible_product_ids.map(&:to_s)
      eligible = lines.select { |line| eligible_ids.include?(line[:product_id]) }
      eligible_subtotal = eligible.sum { |line| line[:subtotal_minor] }
      if eligible.empty? || eligible_subtotal.zero?
        raise checkout_error(:promotion_unavailable, code: "promotion_unavailable")
      end

      allocations = percentage_allocations(eligible)
      result = Orders::LargestRemainderAllocator.call(
        total_minor: discount_minor,
        allocations:
      )
      raise result.error if result.failure?

      amounts = result.value.index_by(&:id).transform_values(&:amount_minor)
      lines.each { |line| line[:promotion_discount_minor] = amounts.fetch(line[:line_key], 0) }
    end

    def percentage_allocations(lines)
      total = lines.sum { |line| line[:subtotal_minor] }
      ranked = lines.map do |line|
        exact = Rational(line[:subtotal_minor] * Orders::LargestRemainderAllocator::BASIS_POINTS, total)
        { id: line[:line_key], floor: exact.floor, remainder: exact - exact.floor }
      end
      remaining = Orders::LargestRemainderAllocator::BASIS_POINTS - ranked.sum { |line| line[:floor] }
      ranked.sort_by { |line| [ -line[:remainder], line[:id] ] }.first(remaining).each { |line| line[:floor] += 1 }
      ranked.map { |line| { id: line[:id], allocation_basis_points: line[:floor] } }
    end

    def resolve_commercial(lines)
      settlement_conversion = convert_to_settlement(lines.first[:subtotal_minor])
      return failure(settlement_conversion) if settlement_conversion.is_a?(Core::BusinessError)

      results = lines.map do |line|
        settlement_amount = convert_to_settlement(line[:subtotal_minor]).fetch(:amount_minor)
        context = Commercial::Resolution::Context.new(
          organization_id: event.organization_id,
          event_id: event.id,
          event_product_id: line[:product_id],
          product_type: line[:type],
          sale_context: sales_channel == "resale" ? "resale" : "primary",
          provider:,
          payment_method:,
          sales_channel:,
          currency: charge_currency,
          settlement_currency:,
          quoted_at:,
          item_face_value_minor: line[:subtotal_minor],
          item_net_value_after_organizer_promotion_minor: line[:subtotal_minor] - line[:promotion_discount_minor],
          eligible_order_subtotal_minor: lines.sum { |item| item[:subtotal_minor] },
          accepted_paid_units: line[:quantity],
          accepted_gross_minor: settlement_amount,
          organizer_payer_selections:
        )
        result = Commercial::ResolveCharges.call(context:)
        return result if result.failure?

        result.value
      end
      Core::BaseService::Result.success(results)
    end

    def build_quote(lines, promotion_quote, commercial_results)
      settlement = settlement_snapshot(lines, promotion_quote, commercial_results)
      return failure(settlement) if settlement.is_a?(Core::BusinessError)

      quote_items = lines.zip(commercial_results).map do |line, commercial_result|
        Orders::QuoteItem.new(
          product_id: line[:product_id],
          line_id: line[:line_id],
          name: line[:name],
          type: line[:type],
          quantity: line[:quantity],
          registration_id: line[:registration_id],
          event_date_ids: line[:event_date_ids],
          venue_event_date_ids: line[:venue_event_date_ids],
          admissions_per_unit: line[:admissions_per_unit],
          price_quote: line[:price_quote],
          base_unit_amount_minor: line[:base_unit_amount_minor],
          commercial_result:,
          subtotal_minor: line[:subtotal_minor],
          promotion_discount_minor: line[:promotion_discount_minor]
        )
      end
      buyer_fees = commercial_results.sum(&:buyer_fee_total)
      organizer_fees = commercial_results.sum(&:organizer_fee_total)
      subsidies = subsidy_total_for(commercial_results, payer: "buyer")
      discount = promotion_quote&.discount_minor.to_i
      subtotal = lines.sum { |line| line[:subtotal_minor] }
      total = subtotal - discount - subsidies + buyer_fees

      return failure(checkout_error(:negative_total, code: "negative_total")) if total.negative?

      success(Orders::Quote.new(
          items: quote_items,
          commercial_results:,
          promotion_quote:,
          charge_currency:,
          settlement_currency:,
          sales_channel:,
          provider:,
          payment_method:,
          quoted_at:,
        expires_at:,
        subtotal_minor: subtotal,
        discount_minor: discount,
        buyer_fee_total: buyer_fees,
        organizer_fee_total: organizer_fees,
        subsidy_total: subsidies,
        total_minor: total,
        settlement_total_minor: settlement.fetch(:total_minor),
        exchange_rate: settlement.fetch(:exchange_rate),
        exchange_rate_source: settlement.fetch(:source),
        exchange_rate_quoted_at: settlement.fetch(:quoted_at),
        exchange_rate_expires_at: expires_at
      ))
    end

    def settlement_snapshot(lines, promotion_quote, commercial_results)
      subtotal = lines.sum { |line| line[:subtotal_minor] }
      discount = promotion_quote&.discount_minor.to_i
      organizer_subsidies = subsidy_total_for(commercial_results, payer: "organizer")
      organizer_fees = commercial_results.sum(&:organizer_fee_total)
      settlement_charge_minor = subtotal - discount + organizer_subsidies - organizer_fees
      return checkout_error(:negative_settlement, code: "negative_settlement") if settlement_charge_minor.negative?

      conversion = convert_to_settlement(settlement_charge_minor)
      return conversion if conversion.is_a?(Core::BusinessError)

      conversion.merge(total_minor: conversion.fetch(:amount_minor))
    end

    def convert_to_settlement(amount_minor)
      metadata = settlement_metadata
      return metadata if metadata.is_a?(Core::BusinessError)

      charge_units = minor_units(charge_currency)
      settlement_units = minor_units(settlement_currency)
      settlement_amount = (amount_minor.to_d / charge_units / metadata.fetch(:rate) * settlement_units)
        .round(0, BigDecimal::ROUND_HALF_UP).to_i
      metadata.merge(amount_minor: settlement_amount).except(:rate)
    end

    def settlement_metadata
      return @settlement_metadata if defined?(@settlement_metadata)

      @settlement_metadata = if charge_currency == settlement_currency
        {
          rate: BigDecimal("1"),
          exchange_rate: BigDecimal("1"),
          source: "same_currency",
          quoted_at:
        }
      else
        rate = Catalog::ExchangeRate.rate_for(from: settlement_currency, to: charge_currency, at: quoted_at)
        if rate
          {
            rate: rate.rate.to_d,
            exchange_rate: (BigDecimal("1") / rate.rate.to_d),
            source: "catalog_exchange_rate",
            quoted_at:
          }
        else
          checkout_error(:unsupported_currency, code: "unsupported_currency")
        end
      end
    end

    def subsidy_total_for(commercial_results, payer:)
      commercial_results.sum do |result|
        result.component_results
          .select { |component| component.component_type == "platform_subsidy" && component.payer == payer }
          .sum(&:amount_minor)
      end
    end

    def minor_units(currency)
      MINOR_UNITS.fetch(currency.to_sym, 100)
    end

    def valid_currency?(currency)
      currency.match?(/\A[A-Z]{3}\z/)
    end

    def checkout_error(key, code:, status: :unprocessable_entity, errors: nil, **options)
      Core::BusinessError.new(
        I18n.t("orders.checkout.errors.#{key}", **options), code:, status:, errors:
      )
    end
  end
end
