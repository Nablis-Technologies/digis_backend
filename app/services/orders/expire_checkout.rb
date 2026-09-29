# frozen_string_literal: true

module Orders
  # Moves due checkouts either to terminal expiry or to the one current
  # payment attempt's bounded settlement grace. The scan is replay-safe: every
  # candidate is rechecked after its order lock, so a webhook or restart that
  # wins the race is never released by a stale query.
  class ExpireCheckout < Core::BaseService
    ACTIVE_PAYMENT_STATUSES = %w[created processing].freeze
    BATCH_SIZE = 100
    FAILURE_DETAIL_LIMIT = 100
    Outcome = Data.define(:action, :payment_id)

    def initialize(now: Time.current)
      @now = now.to_time.utc
    end

    def call
      count = 0
      failures = []

      candidate_order_ids.each_slice(BATCH_SIZE) do |order_ids|
        order_ids.each do |order_id|
          begin
            count += 1 if expire_order(order_id)
          rescue StandardError => error
            failures << candidate_failure(order_id, error)
          end
        end
      end

      return failure(sweep_error(failures, completed_count: count)) if failures.any?

      success(count)
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
      checkout_identity = Orders::Order.where(id: order_id).pick(:buyer_user_id, :event_id)
      raise ActiveRecord::RecordNotFound unless checkout_identity

      outcome = ActiveRecord::Base.transaction do
        CheckoutLock.acquire!(buyer_user_id: checkout_identity.first, event_id: checkout_identity.last)
        order = Orders::Order.lock.find(order_id)
        next Outcome.new(action: :unchanged, payment_id: nil) unless
          order.status.in?(%w[draft pending_payment]) && order.expires_at <= now

        payment = order.payments.current.lock.order(:id).first
        unless payment
          release = Orders::ReleaseCheckout.call_locked(order:, at: now, payment_rows_locked: true)
          raise ExpiryFailure, release.error if release.failure?
          next Outcome.new(action: :released, payment_id: nil)
        end

        if payment.settlement_grace_expires_at <= now
          next Outcome.new(action: :reconcile_grace, payment_id: payment.id)
        end

        move_to_grace!(order, payment)
        Outcome.new(action: :grace_started, payment_id: payment.id)
      end

      finalize_outcome(order_id, outcome)
    end

    def finalize_outcome(order_id, outcome)
      case outcome.action
      when :unchanged
        false
      when :released
        true
      when :grace_started
        enqueue_grace_expiry(outcome.payment_id)
        true
      when :reconcile_grace
        reconcile_expired_grace(order_id, outcome.payment_id)
      else
        raise ExpiryFailure, expiry_error(:checkout_expiry_failed, code: "checkout_expiry_failed")
      end
    end

    def reconcile_expired_grace(order_id, payment_id)
      result = Orders::ExpireSettlementGrace.call(payment_id:, now:)
      raise ExpiryFailure, result.error if result.failure?

      release_stale_checkout!(order_id)
      true
    end

    def release_stale_checkout!(order_id)
      order = Orders::Order.find(order_id)
      return unless order.status.in?(%w[draft pending_payment]) && order.expires_at <= now
      return if Orders::Payment.current.where(order_id:).exists?

      result = Orders::ReleaseCheckout.call(order:, at: now)
      return unless result.failure?

      latest = Orders::Order.find(order_id)
      return unless latest.status.in?(%w[draft pending_payment])

      raise ExpiryFailure, result.error
    end

    def candidate_failure(order_id, error)
      business_error = error.is_a?(ExpiryFailure) ? error.business_error : error
      code = business_error.respond_to?(:code) && business_error.code.present? ?
        business_error.code : "checkout_expiry_failed"
      Rails.logger.error(
        "checkout expiry candidate failed order_id=#{order_id} code=#{code} error=#{error.class.name}"
      )
      { order_id:, code: }
    end

    def sweep_error(failures, completed_count:)
      details = {
        completed_count:,
        failure_count: failures.length,
        failed_candidates: failures.first(FAILURE_DETAIL_LIMIT)
      }
      expiry_error(:checkout_expiry_failed, code: "checkout_expiry_failed", errors: details)
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
      attr_reader :business_error

      def initialize(business_error)
        @business_error = business_error
        super(business_error.message)
      end
    end
  end
end
