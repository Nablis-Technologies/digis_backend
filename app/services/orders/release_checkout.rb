# frozen_string_literal: true

module Orders
  # Releases every still-active checkout hold and closes the order atomically.
  # The command preserves terminal evidence, scopes purchase-limit releases to
  # reserved units only, and publishes one idempotent expiry event.
  class ReleaseCheckout < Core::BaseService
    RELEASE_REASON = "checkout_expired"

    def initialize(order:, reason: RELEASE_REASON, at: Time.current, rows_locked: false,
      payment_rows_locked: false)
      @order = order
      @reason = reason.to_s
      @now = at.to_time.utc
      @rows_locked = rows_locked
      @payment_rows_locked = payment_rows_locked
    end

    # Reuses caller-held checkout/order/payment locks and saves release effects
    # behind a savepoint so a typed failure cannot leave partial mutations.
    def self.call_locked(order:, reason: RELEASE_REASON, at: Time.current, payment_rows_locked: false)
      new(order:, reason:, at:, rows_locked: true, payment_rows_locked:).call
    end

    def call
      if @rows_locked
        return failure(expiry_error(:checkout_release_failed, code: "checkout_release_failed")) unless
          Orders::Order.connection.transaction_open?

        return ActiveRecord::Base.transaction(requires_new: true) do
          release_locked_order!(order, payment_rows_locked: @payment_rows_locked)
        end
      end

      checkout_identity = Orders::Order.where(id: order.id).pick(:buyer_user_id, :event_id)
      return failure(expiry_error(:checkout_not_releasable, code: "checkout_not_releasable")) unless checkout_identity

      ActiveRecord::Base.transaction do
        CheckoutLock.acquire!(buyer_user_id: checkout_identity.first, event_id: checkout_identity.last)
        locked_order = Orders::Order.lock.find(@order.id)
        release_locked_order!(locked_order)
      end
    rescue ActiveRecord::RecordNotFound
      failure(expiry_error(:checkout_not_releasable, code: "checkout_not_releasable"))
    rescue ActiveRecord::RecordInvalid => error
      failure(expiry_error(:checkout_release_failed, code: "checkout_release_failed", errors: error.record.errors.to_hash))
    rescue ReleaseFailure, Core::Error => error
      failure(expiry_error(:checkout_release_failed, code: "checkout_release_failed", errors: { base: [ error.message ] }))
    end

    private

    attr_reader :order, :reason, :now

    def release_locked_order!(locked_order, payment_rows_locked: false)
      return success(locked_order) if locked_order.status == "expired" && locked_order.closed_reason == reason
      return failure(expiry_error(:checkout_not_releasable, code: "checkout_not_releasable")) unless releasable?(locked_order)
      Payment.where(order_id: locked_order.id).current.lock.order(:id).to_a unless payment_rows_locked

      items = OrderItem.where(order_id: locked_order.id)
        .includes(:gift_purchase, registration: :user).lock.order(:id).to_a
      release_inventory!(items)
      release_purchase_limits!(items)
      revoke_gift_purchases!(items)
      release_promotion!(locked_order)
      release_subsidies!(locked_order)
      expire_registrations!(locked_order, items)
      locked_order.update!(status: "expired", closed_reason: reason)
      publish_expiry!(locked_order)
      success(locked_order)
    end

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

    def release_purchase_limits!(items)
      registrations = items.filter_map(&:registration).uniq(&:id)
      registrations.each do |registration|
        next if items.any? { |item| item.gift_purchase && item.registration_id == registration.id }

        unit_numbers = Ticketing::PurchaseLimitAllocation.where(
          registration_id: registration.id,
          user_id: registration.user_id,
          status: "reserved"
        ).order(:unit_number).pluck(:unit_number)
        next if unit_numbers.empty?

        result = Ticketing::PurchaseLimits::Release.call(
          registration:,
          user: registration.user,
          reason: reason_for_purchase_limit,
          idempotency_key: "orders-checkout-expiry-#{locked_order.id}-#{registration.id}",
          unit_numbers:
        )
        raise ReleaseFailure, result.error if result.failure?
      end
    end

    def revoke_gift_purchases!(items)
      order_item_ids = items.filter_map { |item| item.id if item.gift_purchase }
      return if order_item_ids.empty?

      gifts = Orders::GiftPurchase.where(order_item_id: order_item_ids)
        .includes(
          :recipient_user,
          order_item: { registration: [ :user, :created_by, :event, { ticket_type: { event_product: :event } } ] }
        )
        .lock.order(:id)
      gifts.each do |gift_purchase|
        result = GiftPurchases::Revoke.call(
          gift_purchase:, reason: RELEASE_REASON, at: now, row_locked: true
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

    def expire_registrations!(locked_order, items)
      return unless reason == RELEASE_REASON

      registrations = items.filter_map(&:registration).uniq(&:id).sort_by(&:id)
      registrations.each do |registration|
        locked = Ticketing::Registration.lock.find(registration.id)
        next unless locked.pending_payment?

        locked.update!(status: "expired", next_action_snapshot: nil)
        record_registration_expiry!(locked_order, locked)
        result = Ticketing::Registrations::AudienceProof::Release.call(
          registration: locked,
          reason: RELEASE_REASON,
          transition_key: "orders-checkout-expired-#{locked_order.id}-#{locked.id}",
          at: now
        )
        raise ReleaseFailure, result.error if result.failure?
      end
    end

    def record_registration_expiry!(locked_order, registration)
      result = Core::Audit::Record.call(
        audit_key: "ticketing-registration-checkout-expired-#{locked_order.id}-#{registration.id}",
        action: "ticketing.registration.checkout_expired",
        auditable_type: "Ticketing::Registration",
        auditable_id: registration.id,
        audited_changes: { status: [ "pending_payment", "expired" ] },
        metadata: { registration_id: registration.id, transition_reason: RELEASE_REASON }
      )
      raise ReleaseFailure, result.error if result.failure?
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
