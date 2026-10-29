# frozen_string_literal: true

require "digest"
require "json"

module Orders
  # Creates the order boundary and every checkout hold in one transaction.
  # Inventory, promotion, purchase-limit, and subsidy commands are composed in
  # deterministic order; accepted-payment transitions are intentionally left to
  # the later Orders payment workflow.
  class CreateCheckout < Core::BaseService
    HOLD_DURATION = 10.minutes

    def initialize(
      quote:, event:, buyer:, idempotency_key:, sales_channel: nil,
      initiated_by: nil, replaces_order: nil, recovery_context: nil, at: nil,
      gift_intents_by_line_key: {}
    )
      @quote = quote
      @event = event
      @buyer = buyer
      @raw_idempotency_key = idempotency_key
      @sales_channel = (sales_channel || quote.sales_channel).to_s.downcase
      @initiated_by = initiated_by
      @replaces_order = replaces_order
      @recovery_context = recovery_context
      @gift_intents_by_line_key = gift_intents_by_line_key.to_h.transform_keys(&:to_s).freeze
      @now = (at || Time.current).to_time.utc.change(usec: 0)
    rescue NoMethodError, ArgumentError => error
      @initialization_error = error
    end

    def call
      return failure(checkout_error(:invalid_checkout, code: "invalid_checkout")) if @initialization_error
      return failure(checkout_error(:invalid_checkout, code: "invalid_checkout")) unless quote.is_a?(Orders::Quote)
      return failure(checkout_error(:invalid_gift_intent, code: "invalid_gift_intent")) unless valid_gift_line_mapping?

      prepare_idempotency!
      ActiveRecord::Base.transaction do
        CheckoutLock.acquire!(buyer_user_id: buyer.id, event_id: event.id)
        locked_event = Events::Event.lock.find(event.id)
        abort_with(checkout_error(:event_cancelled, code: "event_cancelled", status: :conflict)) if locked_event.status == "cancelled"
        replay = replay_or_conflict!
        return replay if replay
        return failure(checkout_error(:quote_expired, code: "quote_expired", status: :conflict)) if quote_expired?
        validate_event_date_eligibility!(locked_event)
        active_checkout_conflict!

        order = create_order!
        item_records = create_items_and_adjustments!(order)
        reserve_inventory!(order, item_records)
        reserve_promotion!(order)
        reserve_purchase_limits!(order, item_records)
        reserve_subsidies!(order, item_records)
        reconcile_order!(order)

        if order.total_minor.zero?
          accept_zero_total!(order, item_records)
        else
          order.update!(status: "pending_payment")
        end

        publish_checkout!(order)
        success(order)
      end
    rescue CheckoutAbort => error
      failure(error.business_error)
    rescue ArgumentError => error
      failure(checkout_error(:invalid_idempotency_key, code: "invalid_idempotency_key"))
    rescue ActiveRecord::RecordInvalid => error
      failure(
        checkout_error(
          :invalid_checkout,
          code: "invalid_checkout",
          errors: error.record.errors.to_hash
        )
      )
    rescue ActiveRecord::RecordNotUnique
      failure(checkout_error(:idempotency_conflict, code: "idempotency_conflict", status: :conflict))
    end

    private

    attr_reader :quote, :event, :buyer, :sales_channel, :initiated_by, :replaces_order, :recovery_context, :now,
                :idempotency_key, :idempotency_key_digest, :creation_request_digest

    def prepare_idempotency!
      @idempotency_key = Core::IdempotencyKey.new(@raw_idempotency_key)
      @idempotency_key_digest = idempotency_key.digest
      @creation_request_digest = Digest::SHA256.hexdigest(JSON.generate(canonical(
        event_id: event.id,
        buyer_id: buyer.id,
        sales_channel:,
        initiated_by_id: initiated_by&.id,
        replaces_order_id: replaces_order&.id,
        quote_signature: quote.signature,
        gift_intents: gift_intent_fingerprints
      )))
    end

    def gift_intent_fingerprints
      @gift_intents_by_line_key.map do |line_key, intent|
        {
          line_key:,
          registration_id: intent.registration.id,
          recipient_user_id: intent.recipient.id,
          recipient_phone_digest: intent.recipient_phone_digest,
          recipient_email_digest: intent.recipient_email_digest,
          note_digest: Core::KeyedDigest.digest(
            namespace: "orders-gift-purchase-note",
            value: intent.note.to_s
          ),
          expires_at: intent.expires_at.iso8601
        }
      end.sort_by { |attributes| attributes.fetch(:line_key) }
    end

    def valid_gift_line_mapping?
      quote_lines_by_key = quote.items.index_by(&:line_key)
      @gift_intents_by_line_key.all? do |line_key, intent|
        line = quote_lines_by_key[line_key]
        line && line.quantity == 1 && line.registration_id.to_s == intent.registration.id.to_s
      end
    end

    def replay_or_conflict!
      existing = Orders::Order.lock.find_by(idempotency_key_digest:)
      return unless existing
      return success(existing) if existing.creation_request_digest == creation_request_digest

      abort_with(checkout_error(:idempotency_conflict, code: "idempotency_conflict", status: :conflict))
    end

    def active_checkout_conflict!
      active_order = Orders::Order.active_checkouts.lock.find_by(event:, buyer_user: buyer)
      return unless active_order

      recovery = Orders::ActiveCheckoutRecovery.call(order: active_order, context: recovery_context)
      abort_with(checkout_error(
        :active_checkout_exists,
        code: "active_checkout_exists",
        status: :conflict,
        meta: recovery.present? ? { active_checkout: recovery } : nil
      ))
    end

    def validate_event_date_eligibility!(locked_event)
      event_date_ids = quote.items.flat_map do |item|
        Array(item.event_date_ids) + Array(item.venue_event_date_ids)
      end
      error = Orders::EventDateEligibility.error_for(event: locked_event, event_date_ids:, at: now)
      abort_with(error) if error
    end

    def create_order!
      Orders::Order.create!(
        event:,
        buyer_user: buyer,
        sales_channel:,
        initiated_by:,
        replaces_order:,
        status: "draft",
        charge_currency: quote.charge_currency,
        commercial_signature: Orders::CommercialSignature.call(
          commercial_results: quote.commercial_results,
          charge_currency: quote.charge_currency
        ),
        subtotal_minor: quote.subtotal_minor,
        discount_minor: quote.discount_minor,
        subsidy_minor: buyer_subsidy_minor,
        fee_minor: buyer_fee_minor,
        tax_minor: 0,
        adjustment_minor: 0,
        total_minor: quote.total_minor,
        settlement_currency: quote.settlement_currency,
        settlement_total_minor: quote.settlement_total_minor,
        exchange_rate: quote.exchange_rate,
        exchange_rate_source: quote.exchange_rate_source,
        exchange_rate_quoted_at: quote.exchange_rate_quoted_at,
        exchange_rate_expires_at: quote.exchange_rate_expires_at,
        expires_at: quote.expires_at,
        idempotency_key_digest:,
        creation_request_digest:
      )
    end

    def create_items_and_adjustments!(order)
      quote.items.map do |quote_item|
        product = lock_product!(quote_item.product_id)
        gift_intent = gift_intent_for(quote_item.line_key)
        if gift_intent && !product.ticket?
          abort_with(checkout_error(:invalid_checkout, code: "invalid_gift_intent"))
        end
        registration = lock_registration!(
          quote_item.registration_id,
          product:,
          gift_intent:
        )
        item = order.order_items.create!(
          event_product: product,
          registration:,
          name_snapshot: quote_item.name,
          type_snapshot: quote_item.type,
          quantity: quote_item.quantity,
          admissions_per_unit_snapshot: quote_item.admissions_per_unit,
          base_currency: quote_item.price_quote.from_currency,
          base_unit_amount_minor: quote_item.base_unit_amount_minor,
          charge_currency: quote_item.price_quote.charge_currency,
          charge_unit_amount_minor: quote_item.price_quote.amount_minor,
          exchange_rate: quote_item.price_quote.exchange_rate_value || 1,
          discount_minor: 0,
          total_minor: quote_item.subtotal_minor,
          fulfillment_status: "pending"
        )

        commercial = CommercialAdjustmentWriter.call(
          order:,
          order_item: item,
          charge_result: quote_item.commercial_result
        )
        abort_with(commercial.error) if commercial.failure?

        promotion_discount = quote_item.promotion_discount_minor.to_i
        create_promotion_adjustment!(order, item, promotion_discount) if promotion_discount.positive?
        gift_purchase = create_gift_purchase!(order_item: item, intent: gift_intent, line_id: quote_item.line_id) if gift_intent
        { quote_item:, product:, registration:, order_item: item, gift_intent:, gift_purchase: }
      end
    end

    def gift_intent_for(line_key)
      @gift_intents_by_line_key[line_key.to_s]
    end

    def create_gift_purchase!(order_item:, intent:, line_id:)
      token = SecureRandom.urlsafe_base64(32)
      Orders::GiftPurchase.create!(
        order_item:,
        recipient_user: intent.recipient,
        recipient_phone: intent.recipient_phone,
        recipient_phone_digest: intent.recipient_phone_digest,
        recipient_email: intent.recipient_email,
        recipient_email_digest: intent.recipient_email_digest,
        note: intent.note,
        token:,
        token_digest: Orders::GiftPurchase.token_digest_for(token:),
        client_line_id: line_id,
        status: "pending_payment",
        delivery_status: "pending",
        expires_at: intent.expires_at
      )
    end

    def lock_product!(product_id)
      @locked_products ||= {}
      product = @locked_products[product_id.to_s] ||= begin
        Catalog::EventProduct.includes(:ticket_type).lock.find(product_id).tap do |product|
          abort_with(checkout_error(:product_unavailable, code: "product_unavailable")) unless
            product.event_id == event.id && product.status == "active"
        end
      end
      product
    rescue ActiveRecord::RecordNotFound
      abort_with(checkout_error(:product_not_found, code: "product_not_found"))
    end

    def lock_registration!(registration_id, product:, gift_intent: nil)
      return unless registration_id

      registration = Ticketing::Registration.lock.find(registration_id)
      valid_event_and_product = registration.event_id == event.id &&
        registration.ticket_type_id == product.ticket_type&.id
      valid_gift = gift_intent && product.ticket? && registration.id == gift_intent.registration.id &&
        registration.user_id == gift_intent.recipient.id && registration.status == "gift_pending_claim"
      valid = if gift_intent
        valid_event_and_product && valid_gift && gift_intent.recipient.id != buyer.id
      else
        valid_event_and_product && registration.user_id == buyer.id
      end
      abort_with(checkout_error(:registration_scope_invalid, code: "registration_scope_invalid")) unless valid
      payable = gift_intent ? registration.status == "gift_pending_claim" : registration.pending_payment?
      abort_with(checkout_error(:registration_not_payable, code: "registration_not_payable", status: :conflict)) unless payable
      registration
    rescue ActiveRecord::RecordNotFound
      abort_with(checkout_error(:registration_scope_invalid, code: "registration_scope_invalid"))
    end

    def create_promotion_adjustment!(order, item, amount_minor)
      promotion_quote = quote.promotion_quote
      calculation_type = promotion_quote.calculation_type
      fixed_amount_minor = promotion_money_snapshot(promotion_quote.fixed_amount_minor)
      minimum_subtotal_minor = promotion_money_snapshot(promotion_quote.minimum_subtotal_minor)
      maximum_discount_minor = promotion_money_snapshot(promotion_quote.maximum_discount_minor)
      order.order_adjustments.create!(
        order_item: item,
        type: "discount",
        label: I18n.t("orders.checkout.promotion_discount_label"),
        charged_to: "buyer",
        amount_minor: -amount_minor,
        currency: quote.charge_currency,
        refund_policy: "refundable",
        calculation_type:,
        basis_type: calculation_type == "percentage" ? "eligible_order_subtotal" : nil,
        basis_minor: calculation_type == "percentage" ? item.charge_unit_amount_minor * item.quantity : nil,
        rate_bps: promotion_quote.percentage_basis_points,
        fixed_amount_minor:,
        minimum_minor: minimum_subtotal_minor,
        maximum_minor: maximum_discount_minor,
        source_type: "Catalog::Promotion",
        source_id: promotion_quote.promotion_id,
        resolution_evidence: {
          scope: {
            promotion_id: promotion_quote.promotion_id,
            promotion_code_id: promotion_quote.promotion_code_id,
            version: promotion_quote.promotion_version,
            promotion_currency: promotion_quote.promotion_currency,
            charge_currency: promotion_quote.charge_currency,
            exchange_rate_id: promotion_quote.exchange_rate_id,
            exchange_rate_value: promotion_quote.exchange_rate_value,
            original_fixed_amount_minor: promotion_quote.fixed_amount_minor,
            original_minimum_subtotal_minor: promotion_quote.minimum_subtotal_minor,
            original_maximum_discount_minor: promotion_quote.maximum_discount_minor
          },
          rounding: { mode: "half_up" }
        }
      )
    end

    def promotion_money_snapshot(amount_minor)
      return if amount_minor.nil?
      return amount_minor if quote.promotion_quote.promotion_currency == quote.charge_currency

      result = Catalog::Pricing::CurrencyConverter.call(
        amount_minor:,
        from_currency: quote.promotion_quote.promotion_currency,
        to_currency: quote.charge_currency,
        at: quote.promotion_quote.at,
        fx_quote: {
          exchange_rate_id: quote.promotion_quote.exchange_rate_id,
          exchange_rate_value: quote.promotion_quote.exchange_rate_value,
          from_currency: quote.promotion_quote.promotion_currency,
          to_currency: quote.promotion_quote.charge_currency
        }
      )
      return result.value.amount_minor if result.success?

      abort_with(checkout_error(:promotion_unavailable, code: "promotion_unavailable", status: :conflict))
    end

    def reserve_inventory!(order, item_records)
      item_records.sort_by { |record| record[:product].id.to_s }.each do |record|
        item = record[:order_item]
        quote_item = record[:quote_item]
        result = Catalog::Inventory::Reserve.call(
          product: record[:product],
          event_date_ids: quote_item.event_date_ids,
          venue_event_date_ids: quote_item.venue_event_date_ids,
          package_quantity: item.quantity,
          admissions_per_unit: item.admissions_per_unit_snapshot || 1,
          owner: item,
          reservation_group_id: item.id,
          expires_at: order.expires_at
        )
        next if result.success?

        abort_with(
          checkout_error(
            :inventory_unavailable,
            code: "inventory_unavailable",
            status: :conflict,
            errors: { quantity: [ result.error.message ] }
          )
        )
      end
    end

    def reserve_promotion!(order)
      promotion_quote = quote.promotion_quote
      return unless promotion_quote

      promotion = Catalog::Promotion.lock.find(promotion_quote.promotion_id)
      code = Catalog::PromotionCode.lock.find(promotion_quote.promotion_code_id)
      Core::Database::AdvisoryLock.acquire!("catalog-promotion", "checkout", promotion.id, code.id)
      expire_stale_redemptions!(promotion, code)
      revalidate_promotion!(promotion, code, promotion_quote)

      Orders::PromotionRedemption.create!(
        order:,
        promotion:,
        promotion_code: code,
        user: buyer,
        status: "reserved",
        discount_minor: promotion_quote.discount_minor,
        currency: quote.charge_currency,
        idempotency_key: "orders-promotion-#{order.id}",
        expires_at: order.expires_at
      )
    rescue ActiveRecord::RecordNotFound
      abort_with(checkout_error(:promotion_unavailable, code: "promotion_unavailable", status: :conflict))
    end

    def expire_stale_redemptions!(promotion, code)
      Orders::PromotionRedemption.lock
        .where(status: "reserved")
        .where("expires_at <= ?", now)
        .where(promotion_id: promotion.id)
        .where(promotion_code_id: code.id)
        .find_each do |redemption|
          redemption.update!(status: "expired", released_at: now)
        end
    end

    def revalidate_promotion!(promotion, code, promotion_quote)
      valid_quote = promotion.usable_at?(now) && code.usable_at?(now) &&
        promotion.version == promotion_quote.promotion_version &&
        code.id == promotion_quote.promotion_code_id &&
        promotion.currency == promotion_quote.promotion_currency &&
        promotion_quote.charge_currency == quote.charge_currency
      abort_with(checkout_error(:promotion_unavailable, code: "promotion_unavailable", status: :conflict)) unless valid_quote

      active_promotion_count = Orders::PromotionRedemption.where(promotion_id: promotion.id)
        .where(status: "applied").count + Orders::PromotionRedemption.where(promotion_id: promotion.id)
        .active_at(now).count
      active_code_count = Orders::PromotionRedemption.where(promotion_code_id: code.id)
        .where(status: "applied").count + Orders::PromotionRedemption.where(promotion_code_id: code.id)
        .active_at(now).count
      user_count = Orders::PromotionRedemption.where(promotion_id: promotion.id, user_id: buyer.id)
        .where(status: "applied").count + Orders::PromotionRedemption.where(promotion_id: promotion.id, user_id: buyer.id)
        .active_at(now).count

      abort_with(checkout_error(:promotion_unavailable, code: "promotion_unavailable", status: :conflict)) if promotion.redemption_limit && active_promotion_count >= promotion.redemption_limit
      abort_with(checkout_error(:promotion_unavailable, code: "promotion_unavailable", status: :conflict)) if code.redemption_limit && active_code_count >= code.redemption_limit
      abort_with(checkout_error(:promotion_unavailable, code: "promotion_unavailable", status: :conflict)) if promotion.per_user_limit && user_count >= promotion.per_user_limit
    end

    def reserve_purchase_limits!(_order, item_records)
      @purchase_limit_records = item_records.filter_map do |record|
        next unless record[:product].ticket? && record[:registration]

        key = "orders-purchase-limit-#{record[:order_item].id}"
        allocation_user = record[:registration].user
        result = Ticketing::PurchaseLimits::Reserve.call(
          registration: record[:registration],
          user: allocation_user,
          quantity: record[:order_item].quantity,
          expires_at: quote.expires_at,
          idempotency_key: key
        )
        abort_with(purchase_limit_error(result.error)) if result.failure?
        next if result.value.empty?

        { registration: record[:registration], user: allocation_user, key: }
      end
    end

    def reserve_subsidies!(order, item_records)
      subsidy_records = item_records.flat_map do |record|
        Array(record[:quote_item].commercial_result.component_results)
          .select { |component| component.component_type == "platform_subsidy" && component.amount_minor.positive? }
          .map { |component| { component:, order_item: record[:order_item] } }
      end
      subsidy_records.sort_by { |record| record[:component].component_id.to_s }.each do |record|
        component = record[:component]
        budget = subsidy_budget_for(component)
        abort_with(checkout_error(:subsidy_budget_unavailable, code: "subsidy_budget_unavailable", status: :conflict)) unless budget

        result = Commercial::Subsidies::Hold.call(
          budget:,
          order:,
          amount_minor: component.amount_minor,
          currency: component.currency,
          expires_at: order.expires_at,
          idempotency_key: "orders-subsidy-hold-#{order.id}-#{component.component_id}"
        )
        abort_with(subsidy_error(result.error)) if result.failure?
      end
    end

    def subsidy_budget_for(component)
      scope = Commercial::SubsidyBudget.where(
        fee_component_id: component.component_id,
        currency: component.currency
      )
      scope = if component.assignment_id
        scope.where(assignment_id: component.assignment_id)
      elsif component.program_id
        scope.where(program_id: component.program_id)
      else
        scope.where(assignment_id: nil, program_id: nil)
      end
      scope.order(:id).first
    end

    def reconcile_order!(order)
      buyer_adjustments = order.order_adjustments.where(charged_to: "buyer").to_a
      discount = buyer_adjustments.select { |adjustment| adjustment.type == "discount" }.sum { |adjustment| -adjustment.amount_minor }
      subsidy = buyer_adjustments.select(&:subsidy?).sum { |adjustment| -adjustment.amount_minor }
      fees = buyer_adjustments.select { |adjustment| %w[service_fee platform_fee processing_fee resale_platform_fee].include?(adjustment.type) }
        .sum(&:amount_minor)
      tax = buyer_adjustments.select { |adjustment| adjustment.type == "tax" }.sum(&:amount_minor)
      manual = buyer_adjustments.select { |adjustment| adjustment.type == "manual_adjustment" }.sum(&:amount_minor)
      total = order.subtotal_minor - discount - subsidy + fees + tax + manual
      expected = {
        discount_minor: discount,
        subsidy_minor: subsidy,
        fee_minor: fees,
        tax_minor: tax,
        adjustment_minor: manual,
        total_minor: total
      }
      expected_matches_quote = expected[:discount_minor] == quote.discount_minor &&
        expected[:subsidy_minor] == quote.subsidy_total &&
        expected[:fee_minor] == quote.buyer_fee_total &&
        expected[:total_minor] == quote.total_minor
      abort_with(checkout_error(:quote_reconciliation_failed, code: "quote_reconciliation_failed")) unless expected_matches_quote

      order.update!(expected)
      update_item_totals!(order)
    end

    def update_item_totals!(order)
      adjustments_by_item_id = order.order_adjustments
        .where(charged_to: "buyer")
        .where.not(order_item_id: nil)
        .to_a
        .group_by(&:order_item_id)

      order.order_items.to_a.each do |item|
        adjustments = adjustments_by_item_id.fetch(item.id, [])
        discount = adjustments.select { |adjustment| adjustment.type == "discount" }.sum { |adjustment| -adjustment.amount_minor }
        item.update!(discount_minor: discount, total_minor: item.charge_unit_amount_minor * item.quantity + adjustments.sum(&:amount_minor))
      end
    end

    def accept_zero_total!(order, item_records)
      order.update!(status: "paid", paid_at: now)
      confirm_free_order_registrations!(order, item_records)
      commit_inventory!(item_records)
      commit_purchase_limits!
      apply_promotion!(order)
      commit_subsidies!(order)
      result = Orders::FulfillOrder.call(
        order:, payment: nil, idempotency_key: "orders-free-fulfilled-#{order.id}"
      )
      abort_with(result.error) if result.failure?
      order.reload
    end

    def confirm_free_order_registrations!(order, item_records)
      item_records.each do |record|
        registration = record[:registration]
        next unless registration
        next if record[:gift_intent]

        result = Ticketing::Registrations::ConfirmFreeOrder.call(
          registration:,
          order_id: order.id,
          actor: buyer,
          idempotency_key: "orders-zero-total-registration-#{order.id}-#{registration.id}",
          at: now
        )
        abort_with(result.error) if result.failure?

        record[:registration] = result.value
      end
    end

    def commit_inventory!(item_records)
      item_records.each do |record|
        group_id = record[:order_item].id
        next unless Catalog::InventoryReservation.by_group(group_id).exists? || Catalog::VenueCapacityReservation.by_group(group_id).exists?

        result = Catalog::Inventory::Commit.call(reservation_group_id: group_id)
        abort_with(checkout_error(:inventory_commit_failed, code: "inventory_commit_failed")) if result.failure?
      end
    end

    def commit_purchase_limits!
      Array(@purchase_limit_records).each do |record|
        result = Ticketing::PurchaseLimits::Commit.call(
          registration: record[:registration], user: record[:user], idempotency_key: record[:key]
        )
        abort_with(purchase_limit_error(result.error)) if result.failure?
      end
    end

    def apply_promotion!(order)
      redemption = order.promotion_redemption
      return unless redemption

      redemption.update!(status: "applied", applied_at: now)
    end

    def commit_subsidies!(order)
      order.subsidy_reservations.order(:id).each do |reservation|
        result = Commercial::Subsidies::Commit.call(reservation:)
        abort_with(subsidy_error(result.error)) if result.failure?
      end
    end

    def publish_checkout!(order)
      result = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.checkout.created",
        aggregate: order,
        payload: {
          order_id: order.id,
          event_id: order.event_id,
          buyer_user_id: order.buyer_user_id,
          status: order.status,
          total_minor: order.total_minor,
          currency: order.charge_currency,
          quote_signature: quote.signature
        },
        idempotency_key: "orders-checkout-created-#{order.id}"
      )
      abort_with(result.error) if result.failure?
    end

    def buyer_fee_minor
      quote.buyer_fee_total
    end

    def buyer_subsidy_minor
      quote.subsidy_total
    end

    def quote_expired?
      !quote.is_a?(Orders::Quote) || quote.expires_at <= now
    end

    def purchase_limit_error(error)
      checkout_error(
        :purchase_limit_unavailable,
        code: error&.respond_to?(:code) ? error.code : "purchase_limit_unavailable",
        status: :conflict
      )
    end

    def subsidy_error(error)
      code = error&.respond_to?(:code) ? error.code : "subsidy_unavailable"
      checkout_error(:subsidy_unavailable, code:, status: :conflict)
    end

    def abort_with(error)
      raise CheckoutAbort, error
    end

    def checkout_error(key, code:, status: :unprocessable_entity, errors: nil, meta: nil)
      Core::BusinessError.new(
        I18n.t("orders.checkout.errors.#{key}"), code:, status:, errors:, meta:
      )
    end

    def canonical(value)
      case value
      when Hash
        value.stringify_keys.sort.to_h { |key, child| [ key, canonical(child) ] }
      when Array
        value.map { |child| canonical(child) }
      else
        value
      end
    end

    class CheckoutAbort < Core::Error
      attr_reader :business_error

      def initialize(business_error)
        @business_error = business_error
        super(business_error.message)
      end
    end
  end
end
