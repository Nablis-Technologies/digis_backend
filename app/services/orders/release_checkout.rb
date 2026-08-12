# frozen_string_literal: true

module Orders
  # Releases every still-active checkout hold and closes the order atomically.
  # The command preserves terminal evidence, scopes purchase-limit releases to
  # reserved units only, and publishes one idempotent expiry event.
  class ReleaseCheckout < Core::BaseService
    RELEASE_REASON = "checkout_expired"

    def initialize(order:, reason: RELEASE_REASON, at: Time.current)
      @order = order
      @reason = reason.to_s
      @now = at.to_time.utc
    end

    def call
      ActiveRecord::Base.transaction do
        locked_order = Orders::Order.lock.find(@order.id)
        return success(locked_order) if locked_order.status == "expired" && locked_order.closed_reason == reason
        return failure(expiry_error(:checkout_not_releasable, code: "checkout_not_releasable")) unless releasable?(locked_order)

        Payment.where(order_id: locked_order.id).current.lock.order(:id).to_a
        items = OrderItem.where(order_id: locked_order.id).includes(:registration).lock.order(:id).to_a
        release_inventory!(items)
        release_purchase_limits!(locked_order, items)
        release_promotion!(locked_order)
        release_subsidies!(locked_order)
        locked_order.update!(status: "expired", closed_reason: reason)
        publish_expiry!(locked_order)
        success(locked_order)
      end
    rescue ActiveRecord::RecordNotFound
      failure(expiry_error(:checkout_not_releasable, code: "checkout_not_releasable"))
    rescue ActiveRecord::RecordInvalid => error
      failure(expiry_error(:checkout_release_failed, code: "checkout_release_failed", errors: error.record.errors.to_hash))
    end

    private

    attr_reader :order, :reason, :now

    def releasable?(locked_order)
      locked_order.status.in?(%w[draft pending_payment])
    end

    def release_inventory!(items)
      group_ids = items.flat_map do |item|
        inventory_ids = Catalog::InventoryReservation.where(order_item_id: item.id).distinct.pluck(:reservation_group_id)
        venue_ids = Catalog::VenueCapacityReservation.where(order_item_id: item.id).distinct.pluck(:reservation_group_id)
        inventory_ids + venue_ids
      end.uniq.sort

      group_ids.each do |group_id|
        result = Catalog::Inventory::Release.call(reservation_group_id: group_id)
        raise ReleaseFailure, result.error if result.failure?
      end
    end

    def release_purchase_limits!(locked_order, items)
      registrations = items.filter_map(&:registration).uniq(&:id)
      registrations.each do |registration|
        unit_numbers = Ticketing::PurchaseLimitAllocation.where(
          registration_id: registration.id,
          user_id: locked_order.buyer_user_id,
          status: "reserved"
        ).order(:unit_number).pluck(:unit_number)
        next if unit_numbers.empty?

        result = Ticketing::PurchaseLimits::Release.call(
          registration:,
          user: Core::User.find(locked_order.buyer_user_id),
          reason: reason_for_purchase_limit,
          idempotency_key: "orders-checkout-expiry-#{locked_order.id}-#{registration.id}",
          unit_numbers:
        )
        raise ReleaseFailure, result.error if result.failure?
      end
    end

    def release_promotion!(locked_order)
      redemption = PromotionRedemption.lock.find_by(order_id: locked_order.id)
      return unless redemption

      redemption.lock!
      return if redemption.released?

      raise ReleaseFailure, I18n.t("orders.checkout.errors.checkout_release_failed") unless redemption.reserved?

      redemption.update!(status: "released", released_at: now)
    end

    def release_subsidies!(locked_order)
      Commercial::SubsidyReservation.where(order_id: locked_order.id).lock.order(:id).to_a.each do |reservation|
        result = Commercial::Subsidies::Release.call(reservation:)
        raise ReleaseFailure, result.error if result.failure?
      end
    end

    def publish_expiry!(locked_order)
      result = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.checkout.expired",
        aggregate: locked_order,
        payload: {
          order_id: locked_order.id,
          event_id: locked_order.event_id,
          buyer_user_id: locked_order.buyer_user_id,
          closed_reason: reason
        },
        idempotency_key: "orders-checkout-expired-#{locked_order.id}"
      )
      raise ReleaseFailure, result.error if result.failure?
    end

    def reason_for_purchase_limit
      return reason if Ticketing::PurchaseLimitAllocation::RELEASE_REASONS.include?(reason)

      "checkout_expired"
    end

    def expiry_error(key, code:, errors: nil)
      Core::BusinessError.new(
        I18n.t("orders.checkout.errors.#{key}"),
        code:, status: :conflict, errors:
      )
    end

    class ReleaseFailure < Core::Error; end
  end
end
