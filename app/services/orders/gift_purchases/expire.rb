# frozen_string_literal: true

module Orders
  module GiftPurchases
    # Expires the bearer link at the persisted event-end instant. Incomplete
    # registrations release their limits; a consent-pending placeholder ticket
    # is handed to Ticketing for durable credential revocation.
    class Expire < Core::BaseService
      def initialize(gift_purchase:, at: Time.current, after_payment: false)
        @gift_purchase_id = gift_purchase&.id
        @at = at.to_time.utc
        @after_payment = after_payment == true
      rescue ArgumentError, NoMethodError
        @initialization_error = true
      end

      def call
        return failure(expiry_error(:gift_invalid, :not_found)) if @initialization_error || @gift_purchase_id.blank?

        order_id = Orders::OrderItem.joins(:gift_purchase).where(
          orders_gift_purchases: { id: @gift_purchase_id }
        ).pick(:order_id)
        return failure(expiry_error(:gift_invalid, :not_found)) unless order_id

        gift = nil
        ActiveRecord::Base.transaction do
          CheckoutLock.acquire_for_order!(order_id:)
          order = Orders::Order.lock.find(order_id)
          Events::Event.lock.find(order.event_id)
          gift = Orders::GiftPurchase.includes(
            order_item: { registration: :user }
          ).lock.find(@gift_purchase_id)
          next if gift.status.in?(%w[expired revoked]) || gift.expires_at > @at
          next unless gift.status.in?(%w[ready pending_recipient_consent claimed]) ||
            paid_fulfillment_expired?(gift, order)

          expire_unclaimed_registration!(gift, after_payment: @after_payment)
          previous_status = gift.status
          gift.update!(status: "expired", expired_at: @at)
          record_expiry!(gift, previous_status)
        end

        success(gift.reload)
      rescue ActiveRecord::RecordNotFound
        failure(expiry_error(:gift_invalid, :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(expiry_error(:gift_expiry_failed, :unprocessable_entity, errors: exception.record.errors.to_hash))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def paid_fulfillment_expired?(gift, order)
        @after_payment && gift.status == "pending_payment" && order.paid? &&
          order.status == "fulfilled" && gift.order_item.fulfilled?
      end

      def expire_unclaimed_registration!(gift, after_payment:)
        registration = gift.order_item.registration
        if gift.status == "pending_recipient_consent"
          return publish_pending_claim_expiry!(gift, registration)
        end

        eligible_status = gift.status == "ready" || (after_payment && gift.status == "pending_payment")
        return unless eligible_status && registration&.status == "gift_pending_claim"

        release_purchase_limits!(gift, registration)
        registration.update!(status: "expired", next_action_snapshot: nil)
      end

      def publish_pending_claim_expiry!(gift, registration)
        ticket = Ticketing::Ticket.find_by!(order_item_id: gift.order_item_id, unit_number: 1)
        result = Core::Outbox::Publish.call(
          topic: "ticketing",
          event_type: "ticketing.gift_claim.expired",
          aggregate: registration,
          payload: {
            registration_id: registration.id,
            ticket_id: ticket.id,
            expires_at: gift.expires_at.iso8601(6)
          },
          idempotency_key: "ticketing-gift-claim-expired-#{gift.id}"
        )
        raise result.error if result.failure?
      end

      def release_purchase_limits!(gift, registration)
        allocations = Ticketing::PurchaseLimitAllocation.where(
          registration_id: registration.id,
          user_id: gift.recipient_user_id,
          status: %w[reserved committed]
        )
        return unless allocations.exists?

        result = Ticketing::PurchaseLimits::Release.call(
          registration:,
          user: registration.user,
          reason: "expired",
          idempotency_key: "orders-gift-expired-#{gift.id}"
        )
        raise result.error if result.failure?
      end

      def record_expiry!(gift, previous_status)
        result = Core::Audit::Record.call(
          audit_key: "orders-gift-purchase-expired-#{gift.id}",
          action: "orders.gift_purchase.expired",
          auditable_type: gift.class.name,
          auditable_id: gift.id,
          audited_changes: { status: [ previous_status, "expired" ] },
          metadata: { order_item_id: gift.order_item_id, recipient_user_id: gift.recipient_user_id }
        )
        raise result.error if result.failure?
      end

      def expiry_error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("orders.gift_purchases.errors.#{key}"), code: key, status:, errors:
        )
      end
    end
  end
end
