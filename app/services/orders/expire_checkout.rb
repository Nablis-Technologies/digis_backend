# frozen_string_literal: true

module Orders
  # Moves due checkouts either to terminal expiry or to the one current
  # payment attempt's bounded settlement grace. The scan is replay-safe: every
  # candidate is rechecked after its order lock, so a webhook or restart that
  # wins the race is never released by a stale query.
  class ExpireCheckout < Core::BaseService
    ACTIVE_PAYMENT_STATUSES = %w[created processing].freeze
    BATCH_SIZE = 100

    def initialize(now: Time.current)
      @now = now.to_time.utc
    end

    def call
      payment_ids = []
      count = candidate_order_ids.each_slice(BATCH_SIZE).sum do |order_ids|
        order_ids.sum do |order_id|
          result = expire_order(order_id)
          payment_ids << result if result.is_a?(String)
          result ? 1 : 0
        end
      end
      payment_ids.each { |payment_id| enqueue_grace_expiry(payment_id) }
      success(count)
    rescue ExpiryFailure => error
      failure(expiry_error(:checkout_expiry_failed, code: "checkout_expiry_failed", errors: error.errors))
    rescue ActiveRecord::RecordNotFound
      failure(expiry_error(:checkout_expiry_failed, code: "checkout_expiry_failed"))
    end

    private

    attr_reader :now

    def candidate_order_ids
      Orders::Order.active_checkouts
        .where("expires_at <= ?", now)
        .order(:expires_at, :id)
        .pluck(:id)
    end

    def expire_order(order_id)
      ActiveRecord::Base.transaction do
        order = Orders::Order.lock.find(order_id)
        next false unless order.status.in?(%w[draft pending_payment]) && order.expires_at <= now

        payment = order.payments.current.lock.order(:id).first
        unless payment
          release = Orders::ReleaseCheckout.call(order:, at: now)
          raise ExpiryFailure, release.error if release.failure?
          next true
        end

        move_to_grace!(order, payment)
        payment.id
      end
    end

    def move_to_grace!(order, payment)
      grace_deadline = payment.settlement_grace_expires_at
      raise ExpiryFailure, expiry_error(:checkout_expiry_failed, code: "checkout_expiry_failed") unless grace_deadline > now

      items = Orders::OrderItem.where(order_id: order.id).includes(:registration).lock.order(:id).to_a
      inventory_reservations = Catalog::InventoryReservation.where(order_item_id: items.map(&:id)).order(:id).lock.to_a
      venue_reservations = Catalog::VenueCapacityReservation.where(order_item_id: items.map(&:id)).order(:id).lock.to_a

      inventory_reservations.each { |reservation| extend_inventory_reservation!(reservation, grace_deadline) }
      venue_reservations.each { |reservation| extend_inventory_reservation!(reservation, grace_deadline) }
      extend_purchase_limits!(order, items, grace_deadline)
      extend_promotion!(order, grace_deadline)
      extend_subsidies!(order, grace_deadline)
    end

    def extend_inventory_reservation!(reservation, grace_deadline)
      return unless reservation.active?

      reservation.update!(status: "processing", expires_at: grace_deadline)
    end

    def extend_purchase_limits!(order, items, grace_deadline)
      registrations = items.filter_map(&:registration).uniq(&:id)
      registrations.each do |registration|
        allocations = Ticketing::PurchaseLimitAllocation.where(
          registration_id: registration.id,
          user_id: order.buyer_user_id,
          status: "reserved"
        ).order(:unit_number).lock.to_a
        allocations.each { |allocation| allocation.update!(expires_at: grace_deadline) }
      end
    end

    def extend_promotion!(order, grace_deadline)
      redemption = Orders::PromotionRedemption.lock.find_by(order_id: order.id)
      return unless redemption

      redemption.lock!
      return unless redemption.reserved?

      redemption.update!(expires_at: grace_deadline)
    end

    def extend_subsidies!(order, grace_deadline)
      Commercial::SubsidyReservation.where(order_id: order.id).order(:id).lock.to_a.each do |reservation|
        next unless reservation.active?

        result = Commercial::Subsidies::MarkProcessing.call(
          reservation:,
          expires_at: grace_deadline,
          at: now
        )
        raise ExpiryFailure, result.error if result.failure?
      end
    end

    def enqueue_grace_expiry(payment_id)
      Orders::ExpireSettlementGraceJob
        .set(wait_until: Orders::Payment.find(payment_id).settlement_grace_expires_at)
        .perform_later(payment_id)
    end

    def expiry_error(key, code:, errors: nil)
      Core::BusinessError.new(
        I18n.t("orders.checkout.errors.#{key}"),
        code:, status: :conflict, errors:
      )
    end

    class ExpiryFailure < Core::Error
      attr_reader :errors

      def initialize(error)
        @errors = error.respond_to?(:errors) ? error.errors : nil
        super(error.message)
      end
    end
  end
end
