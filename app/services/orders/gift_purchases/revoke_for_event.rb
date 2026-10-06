# frozen_string_literal: true

module Orders
  module GiftPurchases
    # Invalidates every outstanding gift capability after Events has stopped
    # workflows, released registration allocations, and cancelled incomplete
    # registrations. The event lock serializes this pass against gift claims.
    class RevokeForEvent < Core::BaseService
      def initialize(event:, at: Time.current)
        @event_id = event&.id
        @at = at.to_time.utc
      rescue ArgumentError, NoMethodError
        @initialization_error = true
      end

      def call
        return failure(event_error) if @initialization_error || @event_id.blank?

        gifts = Orders::GiftPurchase.joins(order_item: :order)
          .where(orders_orders: { event_id: @event_id }, status: %w[pending_payment ready pending_recipient_consent claimed])
          .includes(
            :recipient_user,
            order_item: { registration: [ :user, :created_by, :event, { ticket_type: { event_product: :event } } ] }
          )
          .lock("FOR UPDATE OF orders_gift_purchases")
          .order(:id)
        gifts.to_a.each do |gift|
          result = Revoke.call(
            gift_purchase: gift,
            reason: "cancelled",
            at: @at,
            row_locked: true
          )
          return failure(result.error) if result.failure?
        end
        success(gifts.size)
      rescue ActiveRecord::RecordNotFound
        failure(event_error)
      end

      private

      def event_error
        Core::BusinessError.new(
          I18n.t("orders.gift_purchases.errors.gift_revoke_failed"),
          code: "gift_revoke_failed",
          status: :unprocessable_entity
        )
      end
    end
  end
end
