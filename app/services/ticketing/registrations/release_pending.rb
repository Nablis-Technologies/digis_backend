# frozen_string_literal: true

module Ticketing
  module Registrations
    # Releases a buyer's abandoned pending registration without deleting its
    # form/consent evidence or allowing an in-flight payment to be discarded.
    class ReleasePending < Core::BaseService
      ACTIVE_PAYMENT_STATUSES = %w[created processing succeeded unknown timeout].freeze

      def initialize(registration:, buyer:, idempotency_key:, at: Time.current)
        @registration_id = registration.id
        @buyer = buyer
        @raw_idempotency_key = idempotency_key
        @at = at.to_time.utc
      end

      def call
        key = Core::IdempotencyKey.new(@raw_idempotency_key)
        Registration.transaction do
          registration = Registration.lock.find(@registration_id)
          return failure(error(:registration_not_owned, status: :forbidden)) unless owned_by_buyer?(registration)
          return success(registration) if registration.status == "cancelled"
          return failure(error(:registration_not_releasable)) unless registration.pending_payment?

          release_checkout!(registration)
          registration.update!(status: "cancelled", cancelled_at: @at, next_action_snapshot: nil)
          record_audit!(registration, key:)
          success(registration)
        end
      rescue ArgumentError => exception
        failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
      rescue Core::Error => exception
        failure(exception)
      rescue ActiveRecord::RecordNotFound
        failure(error(:registration_not_releasable, status: :not_found))
      rescue ActiveRecord::RecordInvalid => exception
        failure(error(:invalid_registration, message: exception.message))
      end

      private

      def owned_by_buyer?(registration)
        registration.user_id == @buyer.id
      end

      def release_checkout!(registration)
        orders = Orders::Order.joins(:order_items)
          .where(orders_order_items: { registration_id: registration.id })
          .order(:id)
          .lock
          .to_a
        return failure!(error(:registration_not_releasable)) if orders.any?(&:paid?)
        return failure!(error(:registration_payment_in_progress)) if payment_in_progress?(orders)

        order = orders.find { |candidate| candidate.status.in?(%w[draft pending_payment]) }
        return unless order

        result = Orders::ReleaseCheckout.call(order:, reason: "buyer_requested", at: @at)
        raise result.error if result.failure?
      end

      def payment_in_progress?(orders)
        Orders::Payment.where(order_id: orders.map(&:id), status: ACTIVE_PAYMENT_STATUSES).exists?
      end

      def record_audit!(registration, key:)
        result = Core::Audit::Record.call(
          audit_key: "ticketing-registration-pending-release-#{key.digest}",
          action: "ticketing.registration.pending_released",
          auditable_type: "Ticketing::Registration",
          auditable_id: registration.id,
          actor_type: "Core::User",
          actor_id: @buyer.id,
          audited_changes: {
            status: [ "pending_payment", "cancelled" ],
            cancelled_at: @at.iso8601
          },
          metadata: { source: "buyer_request" }
        )
        raise result.error if result.failure?
      end

      def failure!(business_error)
        raise business_error
      end

      def error(key, message: nil, status: :conflict)
        Core::BusinessError.new(
          message || I18n.t("ticketing.registration_workflows.errors.#{key}"),
          code: key.to_s,
          status:
        )
      end
    end
  end
end
