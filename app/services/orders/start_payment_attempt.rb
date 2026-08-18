# frozen_string_literal: true

module Orders
  # Starts one bounded provider attempt for an immutable order. The order row
  # serializes attempt numbering and superseding; the transaction commits the
  # local attempt before provider I/O so a timeout remains verifiable rather
  # than silently creating a duplicate charge.
  class StartPaymentAttempt < Core::BaseService
    MAX_ATTEMPTS = 3
    FEE_TYPES = %w[service_fee platform_fee processing_fee resale_platform_fee].freeze

    def initialize(order:, buyer:, provider:, payment_method:, idempotency_key:,
      commercial_signature: nil, at: nil)
      @order = order
      @buyer = buyer
      @provider = provider.to_s.strip.downcase
      @payment_method = payment_method.to_s.strip.downcase
      @raw_idempotency_key = idempotency_key
      @commercial_signature = commercial_signature.to_s.strip.presence
      @now = (at || Time.current).to_time.utc.change(usec: 0)
    rescue NoMethodError, ArgumentError => error
      @initialization_error = error
    end

    def call
      return failure(payment_error(:invalid_payment_attempt, code: "invalid_payment_attempt")) if @initialization_error

      prepare_idempotency!
      adapter = resolve_adapter
      return failure(adapter.error) if adapter.failure?

      state = reserve_attempt!(adapter.value)
      return state[:result] if state[:result]

      cancel_superseded_attempt!(state[:superseded_payment])
      provider_result = create_with_provider(adapter.value, state[:payment])
      persist_provider_result(state[:payment].id, provider_result)
    rescue AttemptAbort => error
      failure(error.business_error)
    rescue ArgumentError
      failure(payment_error(:invalid_idempotency_key, code: "invalid_idempotency_key"))
    rescue ActiveRecord::RecordNotFound
      failure(payment_error(:payment_attempt_unavailable, code: "payment_attempt_unavailable", status: :conflict))
    rescue ActiveRecord::RecordNotUnique
      failure(payment_error(:payment_idempotency_conflict, code: "payment_idempotency_conflict", status: :conflict))
    rescue ActiveRecord::RecordInvalid
      failure(payment_error(:provider_result_invalid, code: "provider_result_invalid", status: :unprocessable_entity))
    end

    private

    attr_reader :order, :buyer, :provider, :payment_method, :raw_idempotency_key, :now,
                :idempotency_key

    def prepare_idempotency!
      key = Core::IdempotencyKey.new(raw_idempotency_key)
      @idempotency_key = key.to_s
    end

    def resolve_adapter
      return failure_result(:invalid_provider, code: "invalid_payment_provider") unless Payment::PROVIDERS.include?(provider)
      return failure_result(:invalid_payment_method, code: "invalid_payment_method") unless Payment::PAYMENT_METHODS.include?(payment_method)

      adapter = Payments::Providers::Registry.fetch(provider)
      return failure_result(:provider_method_unsupported, code: "payment_method_unsupported", status: :unprocessable_entity) unless supported?(adapter, :payment_methods, payment_method)
      return failure_result(:provider_currency_unsupported, code: "payment_currency_unsupported", status: :unprocessable_entity) unless supported?(adapter, :currencies, order_currency)

      success(adapter)
    rescue KeyError
      failure_result(:provider_unavailable, code: "payment_provider_unavailable", status: :service_unavailable)
    rescue ArgumentError
      failure_result(:provider_unavailable, code: "payment_provider_unavailable", status: :service_unavailable)
    end

    def reserve_attempt!(adapter)
      state = {}
      ActiveRecord::Base.transaction do
        locked_order = Orders::Order.includes(:event).lock.find(order.id)
        event = Events::Event.lock.find(locked_order.event_id)
        validate_order!(locked_order, event)
        ensure_commercial_compatibility!(locked_order)

        existing = locked_order.payments.lock.find_by(idempotency_key:)
        state[:result] = replay_or_conflict(existing, locked_order) if existing
        next if state[:result]

        abort_with(payment_error(:payment_already_accepted, code: "payment_already_accepted", status: :conflict)) if locked_order.payments.lock.where.not(accepted_at: nil).exists?
        abort_with(payment_error(:payment_succeeded_pending_acceptance, code: "payment_succeeded_pending_acceptance", status: :conflict)) if locked_order.payments.lock.where(status: "succeeded").exists?

        attempts = locked_order.payments.lock.order(:attempt_number).to_a
        abort_with(payment_error(:payment_attempt_limit_reached, code: "payment_attempt_limit_reached", status: :too_many_requests)) if attempts.length >= MAX_ATTEMPTS

        superseded_payment = attempts.reverse.find(&:current?)
        superseded_payment&.update!(superseded_at: now)
        state[:payment] = build_payment(locked_order, adapter, attempts.length + 1)
        state[:payment].save!
        state[:superseded_payment] = superseded_payment
      end
      state
    end

    def replay_or_conflict(existing, locked_order)
      return success(existing) if same_request?(existing, locked_order)

      abort_with(payment_error(:payment_idempotency_conflict, code: "payment_idempotency_conflict", status: :conflict))
    end

    def same_request?(existing, locked_order)
      existing.order_id == locked_order.id &&
        existing.provider == provider &&
        existing.payment_method == payment_method &&
        existing.amount_minor == locked_order.total_minor &&
        existing.currency == locked_order.charge_currency &&
        existing.commercial_signature == locked_order.commercial_signature
    end

    def validate_order!(locked_order, event)
      valid_owner = locked_order.buyer_user_id == buyer.id
      abort_with(payment_error(:payment_order_not_owned, code: "payment_order_not_owned", status: :forbidden)) unless valid_owner
      abort_with(payment_error(:event_cancelled, code: "event_cancelled", status: :conflict)) if event.status == "cancelled"
      abort_with(payment_error(:payment_attempt_unavailable, code: "payment_attempt_unavailable", status: :conflict)) unless locked_order.pending_payment?
      abort_with(payment_error(:payment_attempt_expired, code: "payment_attempt_expired", status: :conflict)) if locked_order.expires_at <= now
      abort_with(payment_error(:payment_amount_invalid, code: "payment_amount_invalid")) unless locked_order.total_minor.positive?
    end

    def ensure_commercial_compatibility!(locked_order)
      actual_signature = @commercial_signature || locked_order.commercial_signature
      result = Payments::Providers::Registry.check_commercial_compatibility(
        expected_signature: locked_order.commercial_signature,
        actual_signature:
      )
      abort_with(result.error) if result.failure?
    end

    def build_payment(locked_order, adapter, attempt_number)
      buyer_fee_minor, organizer_fee_minor = fee_snapshots(locked_order.id)
      Orders::Payment.new(
        order: locked_order,
        attempt_number:,
        provider:,
        payment_method:,
        status: "created",
        amount_minor: locked_order.total_minor,
        currency: locked_order.charge_currency,
        commercial_signature: locked_order.commercial_signature,
        buyer_fee_minor:,
        organizer_fee_minor:,
        idempotency_key:,
        settlement_grace_minutes: adapter.settlement_grace_minutes,
        settlement_grace_expires_at: locked_order.expires_at + adapter.settlement_grace_minutes.minutes
      )
    end

    def fee_snapshots(order_id)
      adjustments = Orders::OrderAdjustment.where(order_id:).to_a
      buyer_fee = adjustments.select { |adjustment| adjustment.charged_to == "buyer" && FEE_TYPES.include?(adjustment.type) }
        .sum(&:amount_minor)
      organizer_fee = adjustments.select { |adjustment| adjustment.charged_to == "organizer" && FEE_TYPES.include?(adjustment.type) }
        .sum(&:amount_minor)
      [ buyer_fee, organizer_fee ]
    end

    def cancel_superseded_attempt!(payment)
      return unless payment

      adapter = Payments::Providers::Registry.fetch(payment.provider)
      return unless cancellation_supported?(adapter)

      adapter.cancel(
        payment_id: payment.id,
        provider_reference: payment.provider_reference,
        idempotency_key: "orders-payment-cancel-#{payment.id}"
      )
    rescue StandardError => error
      Rails.logger.warn("payment provider cancellation was not confirmed: #{error.class}")
    end

    def cancellation_supported?(adapter)
      value = capability(adapter, :cancel)
      return true if value.nil?

      value == true || Array(value).any? { |entry| entry.to_s.downcase.in?(%w[true cancel cancellation]) }
    end

    def create_with_provider(adapter, payment)
      result = adapter.create(
        payment_id: payment.id,
        order_id: payment.order_id,
        attempt_number: payment.attempt_number,
        provider: payment.provider,
        payment_method: payment.payment_method,
        amount_minor: payment.amount_minor,
        currency: payment.currency,
        commercial_signature: payment.commercial_signature,
        idempotency_key: payment.idempotency_key,
        expires_at: payment.order.expires_at,
        settlement_grace_minutes: payment.settlement_grace_minutes
      )
      result.is_a?(Payments::Providers::Result) ? result : Payments::Providers::Result.from_provider_response(result)
    rescue StandardError
      Payments::Providers::Result.unknown(raw_status: "provider_exception")
    end

    def persist_provider_result(payment_id, result)
      payment = Orders::Payment.lock.find(payment_id)
      status = payment_status_for(result)
      payment.update!(
        status:,
        provider_reference: result.provider_reference,
        failure_code: result.failure_code,
        provider_fee_minor: result.provider_fee_minor,
        provider_fee_currency: result.provider_fee_currency,
        raw_status: result.raw_status.presence || result.status
      )
      success(payment.reload)
    rescue ActiveRecord::RecordInvalid
      payment.update_columns(
        status: "processing",
        provider_reference: result.provider_reference,
        failure_code: nil,
        provider_fee_minor: nil,
        provider_fee_currency: nil,
        raw_status: "provider_result_invalid",
        updated_at: Time.current
      )
      success(payment.reload)
    end

    def payment_status_for(result)
      return "processing" if result.status.in?(%w[unknown timeout])

      { "success" => "succeeded", "failure" => "failed", "cancelled" => "cancelled" }.fetch(result.status)
    end

    def supported?(adapter, key, expected)
      values = capability(adapter, key)
      return true if values.blank?

      Array(values).map { |value| value.to_s.downcase }.include?(expected.to_s.downcase)
    end

    def capability(adapter, key)
      capabilities = adapter.capabilities.to_h
      capabilities[key] || capabilities[key.to_s]
    end

    def order_currency
      order.charge_currency.to_s.upcase
    end

    def failure_result(key, code:, status: :unprocessable_entity)
      failure(payment_error(key, code:, status:))
    end

    def payment_error(key, code:, status: :unprocessable_entity)
      Core::BusinessError.new(I18n.t("orders.payments.errors.#{key}"), code:, status:)
    end

    def abort_with(error)
      raise AttemptAbort, error
    end

    class AttemptAbort < Core::Error
      attr_reader :business_error

      def initialize(error)
        @business_error = error
        super(error.message)
      end
    end
  end
end
