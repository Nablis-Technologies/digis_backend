# frozen_string_literal: true

module Orders
  module GiftPurchases
    # Revokes a gift capability after checkout release, refund, or cancellation.
    # The existing Ticketing refund/cancellation handlers remain responsible
    # for revoking any ticket that has already been issued.
    class Revoke < Core::BaseService
      RELEASE_REASONS = {
        "checkout_expired" => "checkout_expired",
        "refunded" => "refunded",
        "cancelled" => "cancelled"
      }.freeze

      def initialize(gift_purchase:, reason:, at: Time.current, row_locked: false)
        @gift_purchase_id = gift_purchase&.id
        @gift_purchase = gift_purchase if row_locked
        @reason = reason.to_s
        @at = at.to_time.utc
      rescue ArgumentError, NoMethodError
        @initialization_error = true
      end

      def call
        return failure(revoke_error(:gift_invalid, :not_found)) if
          @initialization_error || @gift_purchase_id.blank? || !RELEASE_REASONS.key?(@reason)

        result = nil
        ActiveRecord::Base.transaction do
          gift = @gift_purchase || Orders::GiftPurchase.includes(
            :recipient_user,
            order_item: { registration: :user }
          ).lock.find(@gift_purchase_id)
          if gift.status.in?(%w[revoked expired])
            result = success(gift)
            next
          end

          registration = gift.order_item.registration
          revoke_incomplete_registration!(gift, registration)
          previous_status = gift.status
          gift.update!(status: "revoked", revoked_at: @at)
          record_revocation!(gift, previous_status)
          result = success(gift)
        end
        result
      rescue ActiveRecord::RecordNotFound
        failure(revoke_error(:gift_invalid, :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(revoke_error(:gift_revoke_failed, :unprocessable_entity, errors: exception.record.errors.to_hash))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def revoke_incomplete_registration!(gift, registration)
        return unless registration&.status == "gift_pending_claim"

        release_purchase_limits!(gift, registration)
        status = @reason == "checkout_expired" ? "expired" : "cancelled"
        registration.update!(status:, next_action_snapshot: nil)
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
          reason: RELEASE_REASONS.fetch(@reason),
          idempotency_key: "orders-gift-revoked-#{gift.id}-#{@reason}"
        )
        raise result.error if result.failure?
      end

      def record_revocation!(gift, previous_status)
        result = Core::Audit::Record.call(
          audit_key: "orders-gift-purchase-revoked-#{gift.id}-#{@reason}",
          action: "orders.gift_purchase.revoked",
          auditable_type: gift.class.name,
          auditable_id: gift.id,
          audited_changes: { status: [ previous_status, "revoked" ] },
          metadata: {
            order_item_id: gift.order_item_id,
            recipient_user_id: gift.recipient_user_id,
            reason: @reason
          }
        )
        raise result.error if result.failure?
      end

      def revoke_error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("orders.gift_purchases.errors.#{key}"), code: key, status:, errors:
        )
      end
    end
  end
end
