# frozen_string_literal: true

module Orders
  # Creates one immutable item-refund obligation from the paid order
  # snapshots. This command only records money and provenance: provider
  # submission, inventory changes, and credential transitions belong to later
  # commands after the obligation has committed.
  class CreateItemRefund < Core::BaseService
    AdjustmentAllocation = Data.define(:order_adjustment_id, :amount_minor)
    RefundCalculation = Data.define(:refund_amount, :adjustment_allocations)
    ITEM_REFUND_REASONS = %w[
      event_cancellation
      organizer_ticket_cancellation
      schedule_change
      legal_remedy
      platform_admin_correction
    ].freeze

    def initialize(
      payment:, order_item:, quantity:, reason_code:, idempotency_key:, ticket: nil,
      event_date: nil, event_date_change: nil, event_cancellation: nil, restock: false
    )
      @payment = payment
      @order_item = order_item
      @quantity = quantity.to_i
      @reason_code = reason_code.to_s.strip.downcase
      @idempotency_key = Core::IdempotencyKey.new(idempotency_key)
      @ticket = ticket
      @event_date = event_date
      @event_date_change = event_date_change
      @event_cancellation = event_cancellation
      @restock = restock == true
    rescue ArgumentError => error
      @initialization_error = error
    end

    def call
      return failure(refund_error(:invalid_idempotency_key, code: "invalid_idempotency_key")) if @initialization_error
      return failure(refund_error(:refund_reason_not_allowed, code: "refund_reason_not_allowed")) unless ITEM_REFUND_REASONS.include?(reason_code)

      refund = ActiveRecord::Base.transaction do
        payment = Orders::Payment.lock.find(@payment.id)
        locked_items = Orders::OrderItem.where(order_id: payment.order_id).order(:id).lock.to_a
        locked_tickets = Ticketing::Ticket.where(order_item_id: locked_items.map(&:id)).order(:id).lock.to_a
        locked_dates = lock_dates
        prior_refunds = Orders::Refund.where(payment_id: payment.id).order(:id).lock.to_a
        prior_items = Orders::RefundItem.where(refund_id: prior_refunds.map(&:id)).order(:id).lock.to_a
        refundable_statuses = prior_refunds.each_with_object({}) do |refund, statuses|
          statuses[refund.id] = refund.status
        end
        refundable_prior_items = prior_items.select do |prior_item|
          refundable_statuses[prior_item.refund_id].in?(%w[created pending_funds processing succeeded])
        end
        locked_adjustments = Orders::OrderAdjustment.where(order_id: payment.order_id).order(:id).lock.to_a

        existing = Orders::Refund.lock.find_by(idempotency_key: idempotency_key.to_s)
        if existing
          unless existing.payment_id == payment.id && existing.type == "item_refund"
            raise RefundAbort, refund_error(:idempotency_conflict, code: "idempotency_conflict")
          end
          next existing
        end

        item = locked_items.find { |row| row.id == @order_item.id }
        ticket = locked_tickets.find { |row| row.id == @ticket&.id }
        event_date = locked_dates.find { |row| row.id == @event_date&.id }
        validate_request!(payment, item, ticket, event_date, refundable_prior_items)

        calculation = refund_calculation(
          item:, event_date:, locked_items:, locked_adjustments:, prior_items: refundable_prior_items
        )
        validate_cumulative_value!(item, refundable_prior_items, calculation.refund_amount.amount_minor)
        refund = Orders::Refund.create!(
          payment:,
          event_cancellation:,
          type: "item_refund",
          idempotency_key: idempotency_key.to_s,
          amount_minor: calculation.refund_amount.amount_minor,
          currency: payment.currency,
          status: "created",
          reason_code:,
          reason: I18n.t("orders.refunds.reasons.#{reason_code}")
        )
        refund_item = Orders::RefundItem.create!(
          refund:, order_item: item, ticket:, event_date:,
          event_date_change: @event_date_change,
          quantity:, subtotal_minor: calculation.refund_amount.subtotal_minor,
          amount_minor: calculation.refund_amount.amount_minor, restock:,
          reason: reason_code
        )
        create_adjustment_allocations!(refund_item, calculation.adjustment_allocations)
        publish_refund!(refund, payment, item, ticket, event_date)
        refund
      end

      success(refund)
    rescue RefundAbort => error
      failure(error.business_error)
    rescue ActiveRecord::RecordNotFound
      failure(refund_error(:refund_scope_invalid, code: "refund_scope_invalid"))
    rescue ActiveRecord::RecordInvalid => error
      failure(
        refund_error(
          :refund_failed,
          code: "refund_failed",
          errors: error.record.errors.to_hash
        )
      )
    rescue ArgumentError
      failure(refund_error(:refund_failed, code: "refund_failed"))
    rescue ActiveRecord::RecordNotUnique
      failure(refund_error(:idempotency_conflict, code: "idempotency_conflict"))
    end

    private

    attr_reader :payment, :order_item, :quantity, :reason_code, :idempotency_key,
                :event_date_change, :event_cancellation, :restock

    def lock_dates
      ids = [ @event_date&.id, @event_date_change&.event_date_id ].compact.uniq
      return [] if ids.empty?

      Events::EventDate.where(id: ids).order(:id).lock.to_a
    end

    def validate_request!(locked_payment, item, ticket, event_date, prior_items)
      abort_with(:payment_not_refundable, code: "payment_not_refundable") unless
        locked_payment.status == "succeeded" && locked_payment.accepted_at.present?
      abort_with(:refund_scope_invalid, code: "refund_scope_invalid") unless item
      abort_with(:refund_quantity_invalid, code: "refund_quantity_invalid") unless quantity.positive?
      abort_with(:refund_quantity_invalid, code: "refund_quantity_invalid") if quantity > item.quantity
      abort_with(:refund_item_currency_invalid, code: "refund_item_currency_invalid") unless item.charge_currency == locked_payment.currency

      if item.type_snapshot == "ticket"
        abort_with(:package_required, code: "package_required") unless ticket
      elsif ticket
        abort_with(:refund_scope_invalid, code: "refund_scope_invalid") unless ticket.order_item_id == item.id
      end

      validate_ticket_scope!(item, ticket)
      validate_date_scope!(item, ticket, event_date, prior_items)
      validate_date_change_scope!(locked_payment, event_date)
    end

    def validate_ticket_scope!(item, ticket)
      return unless ticket
      abort_with(:refund_scope_invalid, code: "refund_scope_invalid") unless ticket.order_item_id == item.id
      abort_with(:package_quantity_invalid, code: "package_quantity_invalid") unless quantity == 1
      abort_with(:package_already_refunded, code: "package_already_refunded") if ticket.package_dead?
    end

    def validate_date_scope!(item, ticket, event_date, prior_items)
      if event_date
        abort_with(:date_refund_requires_ticket, code: "date_refund_requires_ticket") unless ticket
        access = Catalog::ProductAccess.find_by(
          event_product_id: item.event_product_id, event_date_id: event_date.id
        )
        allocation = Catalog::ProductDateAllocation.find_by(
          event_product_id: item.event_product_id, event_date_id: event_date.id
        )
        abort_with(:refund_date_unavailable, code: "refund_date_unavailable") unless access && allocation
        abort_with(:refund_date_unavailable, code: "refund_date_unavailable") if admission_used?(ticket, access)
        already_refunded = prior_items.any? do |refund_item|
          refund_item.ticket_id == ticket.id && refund_item.event_date_id == event_date.id
        end
        abort_with(:refund_date_unavailable, code: "refund_date_unavailable") if already_refunded
      elsif event_date_change
        abort_with(:refund_date_change_invalid, code: "refund_date_change_invalid")
      elsif ticket
        already_refunded = prior_items.any? { |refund_item| refund_item.ticket_id == ticket.id }
        abort_with(:package_already_refunded, code: "package_already_refunded") if already_refunded
      end
    end

    def validate_date_change_scope!(locked_payment, event_date)
      return unless event_date_change
      order_event_id = Orders::Order.where(id: locked_payment.order_id).pick(:event_id)
      valid = event_date && event_date_change.event_id == order_event_id &&
        event_date_change.event_date_id == event_date.id
      abort_with(:refund_date_change_invalid, code: "refund_date_change_invalid") unless valid
    end

    def validate_cumulative_value!(item, prior_items, amount_minor)
      prior_amount = prior_items.select { |row| row.order_item_id == item.id }.sum(&:amount_minor)
      abort_with(:refund_item_value_exceeded, code: "refund_item_value_exceeded") if
        amount_minor.positive? && prior_amount + amount_minor > item.total_minor
      abort_with(:refund_quantity_exceeded, code: "refund_quantity_exceeded") if
        prior_items_quantity(item, prior_items) + quantity > item.quantity
    end

    def refund_calculation(item:, event_date:, locked_items:, locked_adjustments:, prior_items:)
      prior_quantity = prior_items_quantity(item, prior_items)
      adjustment_allocations = refundable_adjustments(locked_items, locked_adjustments).select do |allocation|
        allocation.order_item_id == item.id
      end
      item_adjustments = adjustment_allocations.map do |allocation|
        AdjustmentAllocation.new(
          order_adjustment_id: allocation.order_adjustment_id,
          amount_minor: amount_for_units(
            allocation.amount_minor, total_units: item.quantity,
            start_unit: prior_quantity, unit_count: quantity, tie_key: allocation.order_adjustment_id
          )
        )
      end.reject { |allocation| allocation.amount_minor.zero? }
      adjustment_minor = item_adjustments.sum(&:amount_minor)
      subtotal_minor = item.charge_unit_amount_minor * quantity

      unless event_date
        amount = Orders::RefundAmount.new(
          subtotal_minor:, adjustment_minor:, amount_minor: subtotal_minor + adjustment_minor,
          currency: item.charge_currency
        )
        return RefundCalculation.new(refund_amount: amount, adjustment_allocations: item_adjustments)
      end

      allocations = Catalog::ProductDateAllocation.where(
        event_product_id: item.event_product_id
      ).order(:event_date_id).to_a
      result = Orders::AllocateDateValue.call(
        subtotal_minor:, adjustment_minor:, currency: item.charge_currency,
        date_allocations: allocations.map { |allocation|
          { event_date_id: allocation.event_date_id, allocation_basis_points: allocation.allocation_basis_points }
        }
      )
      raise result.error if result.failure?
      date_amount = result.value.find { |allocation| allocation.event_date_id == event_date.id }.refund_amount
      RefundCalculation.new(
        refund_amount: date_amount,
        adjustment_allocations: allocate_date_adjustments(item_adjustments, date_amount.adjustment_minor)
      )
    end

    def allocate_date_adjustments(adjustments, amount_minor)
      return [] if amount_minor.zero?

      candidates = adjustments.select do |allocation|
        allocation.amount_minor.positive? == amount_minor.positive?
      end
      abort_with(:refund_failed, code: "refund_failed") if candidates.empty?

      result = Orders::LargestRemainderAllocator.weighted(
        total_minor: amount_minor.abs,
        allocations: candidates.map do |allocation|
          { id: allocation.order_adjustment_id, weight: allocation.amount_minor.abs }
        end
      )
      result.value.filter_map do |allocation|
        next if allocation.amount_minor.zero?

        AdjustmentAllocation.new(
          order_adjustment_id: allocation.id,
          amount_minor: amount_minor.negative? ? -allocation.amount_minor : allocation.amount_minor
        )
      end
    end

    def refundable_adjustments(items, adjustments)
      result = Orders::AllocateRefundAdjustments.call(
        items: items.map { |item|
          { id: item.id, subtotal_minor: item.charge_unit_amount_minor * item.quantity }
        },
        adjustments:
      )
      raise result.error if result.failure?
      result.value
    end

    def amount_for_units(total_minor, total_units:, start_unit:, unit_count:, tie_key:)
      return 0 if total_minor.zero?

      result = Orders::LargestRemainderAllocator.weighted(
        total_minor: total_minor.abs,
        allocations: total_units.times.map { |index| { id: "#{tie_key}:#{index}", weight: 1 } }
      )
      amount = result.value.slice(start_unit, unit_count).sum(&:amount_minor)
      total_minor.negative? ? -amount : amount
    end

    def prior_items_quantity(item, prior_items)
      prior_items.select { |row| row.order_item_id == item.id }.sum(&:quantity)
    end

    def admission_used?(ticket, access)
      Ticketing::AdmissionUse.joins(:admission_slot).where(
        ticketing_admission_slots: { ticket_id: ticket.id }, product_access_id: access.id
      ).exists?
    end

    def create_adjustment_allocations!(refund_item, allocations)
      allocations.each do |allocation|
        Orders::RefundAdjustmentAllocation.create!(
          refund_item:, order_adjustment_id: allocation.order_adjustment_id,
          amount_minor: allocation.amount_minor
        )
      end
    end

    def publish_refund!(refund, locked_payment, item, ticket, event_date)
      result = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.refund.created",
        aggregate: locked_payment,
        payload: {
          refund_id: refund.id,
          payment_id: locked_payment.id,
          order_id: locked_payment.order_id,
          order_item_id: item.id,
          ticket_id: ticket&.id,
          event_date_id: event_date&.id,
          reason_code: refund.reason_code
        },
        idempotency_key: "orders-refund-created-#{refund.id}"
      )
      raise result.error if result.failure?
    end

    def abort_with(key, code:)
      raise RefundAbort, refund_error(key, code:)
    end

    def refund_error(key, code:, errors: nil)
      Core::BusinessError.new(
        I18n.t("orders.refunds.errors.#{key}"), code:, status: :conflict, errors:
      )
    end

    class RefundAbort < Core::Error
      attr_reader :business_error

      def initialize(error)
        @business_error = error
        super(error.message)
      end
    end
  end
end
