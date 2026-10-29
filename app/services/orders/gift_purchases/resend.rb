# frozen_string_literal: true

module Orders
  module GiftPurchases
    # Queues an explicit payer-requested redelivery of the same gift link.
    # A persisted revision gives provider idempotency keys a new send identity
    # without rotating or returning the bearer capability.
    class Resend < Core::BaseService
      def initialize(gift_purchase:, actor:, idempotency_key:, at: Time.current)
        @gift_purchase_id = gift_purchase&.id
        @actor = actor
        @raw_idempotency_key = idempotency_key
        @at = at.to_time.utc
      rescue ArgumentError, NoMethodError
        @initialization_error = true
      end

      def call
        return failure(error(:invalid_idempotency_key, :bad_request)) if @initialization_error

        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        gift = load_gift
        return failure(error(:gift_invalid, :not_found)) unless gift
        return failure(error(:gift_resend_forbidden, :forbidden)) unless payer?(gift)

        audit_key = "orders-gift-delivery-resend-#{gift.id}-#{key.digest}"
        request_digest = request_digest_for(gift, key)
        replay = replay_result(gift, audit_key:, request_digest:)
        return replay if replay

        outcome = nil
        ActiveRecord::Base.transaction do
          locked = Orders::GiftPurchase.includes(order_item: { order: :event }).lock.find(gift.id)
          replay = replay_result(locked, audit_key:, request_digest:)
          if replay
            outcome = replay
            raise ActiveRecord::Rollback
          end

          invalid = validate(locked)
          if invalid
            outcome = failure(invalid)
            raise ActiveRecord::Rollback
          end

          locked.update!(delivery_revision: locked.delivery_revision + 1, delivery_status: "pending", delivered_at: nil)
          record_resend!(locked, key, audit_key, request_digest)
          publish_delivery_request!(locked, key)
          outcome = success(locked.reload)
        end
        outcome
      rescue ArgumentError
        failure(error(:invalid_idempotency_key, :bad_request))
      rescue ActiveRecord::RecordNotFound
        failure(error(:gift_invalid, :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:gift_delivery_request_failed, :unprocessable_entity, errors: exception.record.errors.to_hash))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      def load_gift
        Orders::GiftPurchase.includes(order_item: { order: :event }).find_by(id: @gift_purchase_id)
      end

      def payer?(gift)
        @actor.is_a?(Core::User) && gift.order_item.order.buyer_user_id == @actor.id
      end

      def validate(gift)
        return error(:gift_resend_forbidden, :forbidden) unless payer?(gift)
        return error(:gift_revoked, :gone) if gift.status == "revoked"
        return error(:gift_expired, :gone) if gift.status == "expired" || gift.expires_at <= @at
        return error(:gift_not_ready, :conflict) unless gift.status.in?(%w[ready claimed])
        return error(:gift_not_ready, :conflict) unless gift.order_item.order.status == "fulfilled" &&
          gift.order_item.order.paid? && gift.order_item.fulfilled?
        return error(:event_cancelled, :gone) if gift.order_item.order.event.status == "cancelled"

        nil
      end

      def request_digest_for(gift, key)
        Core::KeyedDigest.digest(
          namespace: "orders-gift-delivery-resend:#{gift.id}",
          value: [ gift.id, @actor.id, key.digest ].join(":")
        )
      end

      def replay_result(gift, audit_key:, request_digest:)
        audit = Core::AuditLog.find_by(audit_key:)
        return unless audit
        return failure(error(:idempotency_conflict, :conflict)) unless audit.metadata["request_digest"] == request_digest

        success(gift)
      end

      def record_resend!(gift, key, audit_key, request_digest)
        result = Core::Audit::Record.call(
          audit_key:,
          action: "orders.gift_purchase.delivery_resend_requested",
          auditable_type: gift.class.name,
          auditable_id: gift.id,
          actor_type: @actor.class.name,
          actor_id: @actor.id,
          audited_changes: { delivery_revision: [ gift.delivery_revision - 1, gift.delivery_revision ] },
          metadata: {
            order_item_id: gift.order_item_id,
            idempotency_key_digest: key.digest,
            request_digest:
          }
        )
        raise result.error if result.failure?
      end

      def publish_delivery_request!(gift, key)
        result = Core::Outbox::Publish.call(
          topic: "orders",
          event_type: "orders.gift_purchase.delivery_requested",
          aggregate: gift,
          payload: { gift_purchase_id: gift.id },
          idempotency_key: "orders-gift-delivery-request-#{gift.id}-#{key.digest}"
        )
        raise result.error if result.failure?
      end

      def error(key, status, errors: nil)
        Core::BusinessError.new(
          I18n.t("orders.gift_purchases.errors.#{key}"), code: key.to_s, status:, errors:
        )
      end
    end
  end
end
