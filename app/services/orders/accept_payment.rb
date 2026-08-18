# frozen_string_literal: true

module Orders
  # Serializes a verified success under order → payment → reservation locks.
  # The first eligible current success commits the order; every superseded,
  # late, or losing success remains succeeded evidence and creates a full
  # reversal without reacquiring released capacity.
  class AcceptPayment < Core::BaseService
    def initialize(payment:, payment_event: nil, at: Time.current)
      @payment = payment
      @payment_event = payment_event
      @now = at.to_time.utc
    end

    def call
      ActiveRecord::Base.transaction do
        order_id = Orders::Payment.where(id: @payment.id).pick(:order_id)
        order = Orders::Order.includes(:event).lock.find(order_id)
        event = Events::Event.lock.find(order.event_id)
        payment = Orders::Payment.lock.find(@payment.id)
        order.event = event
        payment.order = order

        payment.update!(status: "succeeded", succeeded_at: payment.succeeded_at || now)
        if payment.accepted?
          post_accepted_sale!(payment)
          return success(payment)
        end

        reason = rejection_reason(payment, order)
        if reason
          reverse = Orders::CreatePaymentReversal.call(payment:, reason_code: reason)
          raise AcceptanceFailure, reverse.error if reverse.failure?
          return success(payment)
        end

        payment.update!(accepted_at: now)
        order.update!(status: "paid", paid_at: now)
        commit_reservations!(order)
        commit_purchase_limits!(order)
        apply_promotion!(order)
        commit_subsidies!(order)

        fulfillment = Orders::FulfillOrder.call(order:, payment:)
        raise AcceptanceFailure, fulfillment.error if fulfillment.failure?
        post_accepted_sale!(payment)

        success(payment.reload)
      end
    rescue AcceptanceFailure => error
      failure(error.business_error)
    rescue ActiveRecord::RecordInvalid => error
      failure(
        Core::BusinessError.new(
          I18n.t("orders.payments.fulfillment.errors.fulfillment_failed"),
          code: "fulfillment_failed", status: :conflict,
          errors: error.record.errors.to_hash
        )
      )
    end

    private

    attr_reader :payment, :payment_event, :now

    def rejection_reason(locked_payment, locked_order)
      return "superseded_attempt" if locked_payment.superseded_at.present?
      return "event_cancelled" if locked_order.event.status == "cancelled"
      return "late_payment" if locked_order.closed?
      return "duplicate_payment" if Orders::Payment.where(order_id: locked_order.id).where.not(id: locked_payment.id).where.not(accepted_at: nil).exists?
      return "duplicate_payment" unless locked_order.pending_payment?
      return "late_payment" unless reservations_eligible?(locked_payment, locked_order)

      nil
    end

    def reservations_eligible?(locked_payment, locked_order)
      item_ids = Orders::OrderItem.where(order_id: locked_order.id).pluck(:id)
      inventory = Catalog::InventoryReservation.where(order_item_id: item_ids).to_a
      venue = Catalog::VenueCapacityReservation.where(order_item_id: item_ids).to_a
      reservations = inventory + venue
      return true if reservations.empty?

      reservations.all? do |reservation|
        if reservation.status == "held"
          locked_payment.settlement_grace_expires_at >= now && reservation.expires_at >= now
        elsif reservation.status == "processing"
          locked_payment.settlement_grace_expires_at >= now && reservation.expires_at >= now
        else
          false
        end
      end
    end

    def commit_reservations!(locked_order)
      item_ids = Orders::OrderItem.where(order_id: locked_order.id).pluck(:id)
      group_ids = Catalog::InventoryReservation.where(order_item_id: item_ids).distinct.pluck(:reservation_group_id)
      group_ids |= Catalog::VenueCapacityReservation.where(order_item_id: item_ids).distinct.pluck(:reservation_group_id)
      group_ids.sort.each do |group_id|
        result = Catalog::Inventory::Commit.call(reservation_group_id: group_id)
        raise AcceptanceFailure, result.error if result.failure?
      end
    end

    def commit_purchase_limits!(locked_order)
      items = Orders::OrderItem.where(order_id: locked_order.id).includes(:registration).to_a
      items.each do |item|
        registration = item.registration
        next unless registration
        next unless Ticketing::PurchaseLimitAllocation.where(registration_id: registration.id, status: %w[reserved committed]).exists?

        result = Ticketing::PurchaseLimits::Commit.call(
          registration:, user: Core::User.find(locked_order.buyer_user_id),
          idempotency_key: "orders-purchase-limit-#{item.id}", at: now
        )
        raise AcceptanceFailure, result.error if result.failure?
      end
    end

    def apply_promotion!(locked_order)
      redemption = Orders::PromotionRedemption.lock.find_by(order_id: locked_order.id)
      return unless redemption
      return if redemption.applied?

      raise AcceptanceFailure, promotion_error unless redemption.reserved? && redemption.expires_at >= now

      redemption.update!(status: "applied", applied_at: now)
    end

    def commit_subsidies!(locked_order)
      Commercial::SubsidyReservation.where(order_id: locked_order.id).order(:id).lock.to_a.each do |reservation|
        result = Commercial::Subsidies::Commit.call(reservation:, at: now)
        raise AcceptanceFailure, result.error if result.failure?
      end
    end

    # Ledger posting stays inside the acceptance transaction so an accepted
    # primary payment cannot commit without its immutable organizer facts.
    # Resale economics are posted by Marketplace's seller ledger instead of
    # creating a primary organizer sale ledger entry.
    def post_accepted_sale!(locked_payment)
      return success([]) if locked_payment.order.sales_channel == "resale"

      result = Finance::PostAcceptedSale.call(payment: locked_payment, at: now)
      raise AcceptanceFailure, result.error if result.failure?
    end

    def promotion_error
      Core::BusinessError.new(
        I18n.t("orders.payments.fulfillment.errors.promotion_reservation_invalid"),
        code: "promotion_reservation_invalid", status: :conflict
      )
    end

    class AcceptanceFailure < Core::Error
      attr_reader :business_error

      def initialize(error)
        @business_error = error.is_a?(Core::BusinessError) ? error :
          Core::BusinessError.new(error.message, code: "payment_acceptance_failed", status: :conflict)
        super(@business_error.message)
      end
    end
  end
end
