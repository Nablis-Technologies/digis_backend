# frozen_string_literal: true

module Orders
  # Replaces one active checkout without multiplying holds. The buyer/event
  # advisory lock serializes restarts, while the surrounding transaction makes
  # source closure, hold release, and replacement creation all-or-nothing.
  class RestartCheckout < Core::BaseService
    MAX_REPLACEMENTS = 2
    ROLLING_WINDOW = 1.hour
    ACTIVE_PAYMENT_STATUSES = %w[created processing].freeze

    def initialize(old_order:, buyer:, quote:, idempotency_key:, at: nil)
      @old_order = old_order
      @buyer = buyer
      @quote = quote
      @raw_idempotency_key = idempotency_key
      @now = (at || Time.current).to_time.utc.change(usec: 0)
    rescue NoMethodError, ArgumentError => error
      @initialization_error = error
    end

    def call
      return failure(restart_error(:invalid_checkout, code: "invalid_checkout")) if @initialization_error
      return failure(restart_error(:invalid_checkout, code: "invalid_checkout")) unless quote.is_a?(Orders::Quote)

      prepare_idempotency!
      ActiveRecord::Base.transaction do
        CheckoutLock.acquire!(buyer_user_id: buyer.id, event_id: old_order.event_id)
        source = Orders::Order.lock.find(old_order.id)

        replay = replay_or_conflict!(source)
        return replay if replay

        validate_source!(source)
        enforce_restart_limit!(source)
        release_holds!(source)
        close_source!(source)
        publish_restart!(source)

        replacement = Orders::CreateCheckout.call(
          quote:,
          event: source.event,
          buyer:,
          idempotency_key: raw_idempotency_key,
          replaces_order: source,
          at: now
        )
        abort_with(replacement.error) if replacement.failure?
        success(replacement.value)
      end
    rescue RestartAbort => error
      failure(error.business_error)
    rescue ArgumentError
      failure(restart_error(:invalid_idempotency_key, code: "invalid_idempotency_key"))
    rescue ActiveRecord::RecordNotFound
      failure(restart_error(:checkout_restart_unavailable, code: "checkout_restart_unavailable", status: :conflict))
    rescue ActiveRecord::RecordNotUnique
      failure(restart_error(:idempotency_conflict, code: "idempotency_conflict", status: :conflict))
    end

    private

    attr_reader :old_order, :buyer, :quote, :raw_idempotency_key, :now,
                :idempotency_key_digest

    def prepare_idempotency!
      @idempotency_key_digest = Core::IdempotencyKey.new(raw_idempotency_key).digest
    end

    def replay_or_conflict!(source)
      existing = Orders::Order.lock.find_by(idempotency_key_digest:)
      return unless existing
      return success(existing) if existing.replaces_order_id == source.id

      abort_with(restart_error(:idempotency_conflict, code: "idempotency_conflict", status: :conflict))
    end

    def validate_source!(source)
      valid_owner = source.buyer_user_id == buyer.id && source.event_id == old_order.event_id
      abort_with(restart_error(:checkout_restart_unavailable, code: "checkout_restart_unavailable", status: :conflict)) unless valid_owner
      abort_with(restart_error(:checkout_restart_payment_in_progress, code: "checkout_restart_payment_in_progress", status: :conflict)) if active_payment_in_progress?(source)
      return if source.status.in?(%w[draft pending_payment])

      abort_with(restart_error(:checkout_restart_unavailable, code: "checkout_restart_unavailable", status: :conflict))
    end

    def enforce_restart_limit!(source)
      count = Orders::Order.where(
        buyer_user_id: source.buyer_user_id,
        event_id: source.event_id
      ).where.not(replaces_order_id: nil).where("created_at >= ?", now - ROLLING_WINDOW).count
      return if count < MAX_REPLACEMENTS

      abort_with(restart_error(:checkout_restart_limit_exceeded, code: "checkout_restart_limit_exceeded", status: :too_many_requests))
    end

    def release_holds!(source)
      items = source.order_items.lock.to_a
      items.each { |item| release_inventory!(item) }
      release_purchase_limits!(items)
      release_promotion!(source)
      release_subsidies!(source)
    end

    def release_inventory!(item)
      return unless Catalog::InventoryReservation.by_group(item.id).exists? ||
        Catalog::VenueCapacityReservation.by_group(item.id).exists?

      result = Catalog::Inventory::Release.call(reservation_group_id: item.id)
      abort_with(restart_error(:checkout_restart_release_failed, code: "checkout_restart_release_failed")) if result.failure?
    end

    def release_purchase_limits!(items)
      items.filter_map(&:registration).uniq(&:id).each do |registration|
        next unless Ticketing::PurchaseLimitAllocation.where(
          registration_id: registration.id, user_id: buyer.id, status: %w[reserved committed]
        ).exists?

        result = Ticketing::PurchaseLimits::Release.call(
          registration:,
          user: buyer,
          reason: "void",
          idempotency_key: "orders-restart-#{old_order.id}"
        )
        abort_with(restart_error(:checkout_restart_release_failed, code: "checkout_restart_release_failed")) if result.failure?
      end
    end

    def release_promotion!(source)
      redemption = source.promotion_redemption
      return unless redemption

      redemption.lock!
      return if redemption.released?
      return if redemption.status == "reserved" && redemption.update!(status: "released", released_at: now)

      abort_with(restart_error(:checkout_restart_release_failed, code: "checkout_restart_release_failed"))
    end

    def release_subsidies!(source)
      source.subsidy_reservations.lock.order(:id).to_a.each do |reservation|
        result = Commercial::Subsidies::Release.call(reservation:)
        abort_with(restart_error(:checkout_restart_release_failed, code: "checkout_restart_release_failed")) if result.failure?
      end
    end

    def close_source!(source)
      source.update!(status: "cancelled", closed_reason: "buyer_restart")
    end

    def publish_restart!(source)
      result = Core::Outbox::Publish.call(
        topic: "orders",
        event_type: "orders.checkout.restarted",
        aggregate: source,
        payload: {
          order_id: source.id,
          event_id: source.event_id,
          buyer_user_id: source.buyer_user_id,
          replacement_request_digest: idempotency_key_digest
        },
        idempotency_key: "orders-checkout-restarted-#{source.id}-#{idempotency_key_digest}"
      )
      abort_with(result.error) if result.failure?
    end

    # Task 5 adds Orders::Payment and its `payments` association. Keeping this
    # capability check here lets Task 4 reject in-flight attempts immediately
    # without inventing a payment table before its owning task.
    def active_payment_in_progress?(source)
      return false unless source.respond_to?(:payments)

      source.payments.where(status: ACTIVE_PAYMENT_STATUSES).exists?
    end

    def restart_error(key, code:, status: :unprocessable_entity)
      Core::BusinessError.new(I18n.t("orders.checkout.errors.#{key}"), code:, status:)
    end

    def abort_with(error)
      raise RestartAbort, error
    end

    class RestartAbort < StandardError
      attr_reader :business_error

      def initialize(error)
        @business_error = error
        super(error.message)
      end
    end
  end
end
