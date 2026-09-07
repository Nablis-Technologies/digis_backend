# frozen_string_literal: true

require "digest"

module Orders
  # Reconciles a buyer-owned event payment and returns its current wallet
  # projection. Provider verification is only used for non-terminal payments;
  # ticket issuance remains on the durable fulfillment outbox path.
  class PaymentRefresh < Core::BaseService
    TERMINAL_STATUSES = %w[failed cancelled reversed].freeze

    # Prevents a tight refresh retry loop from repeatedly calling a provider.
    # The cache write is atomic for stores that support `unless_exist`, and the
    # payment ID is hashed so the cache key does not retain a raw identifier.
    class VerificationThrottle
      INTERVAL = 2.seconds

      def initialize(cache: Rails.cache, interval: INTERVAL)
        @cache = cache
        @interval = interval
      end

      def allowed?(payment_id:)
        @cache.write(cache_key(payment_id), true, expires_in: @interval, unless_exist: true)
      end

      private

      def cache_key(payment_id)
        digest = Digest::SHA256.hexdigest(payment_id.to_s)
        "orders/payment-refresh/#{digest}"
      end
    end

    def initialize(payment:, buyer:, idempotency_key:, throttle: VerificationThrottle.new)
      @payment_id = payment.id
      @buyer = buyer
      @raw_idempotency_key = idempotency_key
      @throttle = throttle
    end

    def call
      Core::IdempotencyKey.new(@raw_idempotency_key)
      payment = load_payment
      return failure(error(:event_payment_required)) unless payment&.event_payment?
      return failure(error(:payment_order_not_owned, status: :forbidden)) unless buyer?(payment)
      return success(projection(payment)) if terminal?(payment)
      return success(projection(payment)) unless @throttle.allowed?(payment_id: payment.id)

      event = record_verified_event(payment)
      processing = Orders::ProcessPaymentEvent.call(event_id: event.id)
      return failure(processing.error) if processing.failure?

      success(projection(load_payment))
    rescue ArgumentError => exception
      failure(error(:invalid_idempotency_key, message: exception.message, status: :bad_request))
    rescue Core::Error => exception
      failure(exception)
    rescue ActiveRecord::RecordNotFound
      failure(error(:payment_not_found, status: :not_found))
    end

    private

    def load_payment
      Orders::Payment.includes(
        order: [ :event, :order_items, :order_adjustments ]
      ).find(@payment_id)
    end

    def buyer?(payment)
      payment.order&.buyer_user_id.to_s == @buyer.id.to_s
    end

    def terminal?(payment)
      payment.accepted_at.present? || TERMINAL_STATUSES.include?(payment.status)
    end

    def record_verified_event(payment)
      reference = payment.provider_reference.presence || payment.idempotency_key
      result = Orders::RecordPaymentCallback.call(
        provider: payment.provider,
        transaction_reference: reference,
        provider_reference: payment.provider_reference,
        callback_status: nil
      )
      raise result.error if result.failure?

      result.value
    end

    def projection(payment)
      tickets = wallet_tickets(payment)
      {
        state: state_for(payment, tickets),
        payment:,
        order: payment.order,
        tickets:
      }
    end

    def wallet_tickets(payment)
      return Ticketing::Ticket.none unless payment.order

      order_item_ids = payment.order.order_items.map(&:id)
      return Ticketing::Ticket.none if order_item_ids.empty?

      Ticketing::Ticket.where(owner_user_id: @buyer.id, order_item_id: order_item_ids)
        .includes(
          :event,
          :admission_slots,
          { current_credential_generation: :credentials },
          event_product: [ :ticket_type, { product_accesses: { event_date: :venue } } ]
        ).order(:id)
    end

    def state_for(payment, tickets)
      return "ready" if payment.accepted_at.present? && tickets.any?
      return "terminal" if TERMINAL_STATUSES.include?(payment.status)

      "pending"
    end

    def error(key, message: nil, status: :unprocessable_entity)
      Core::BusinessError.new(message || I18n.t("orders.payments.refresh.errors.#{key}"), code: key.to_s, status:)
    end
  end
end
