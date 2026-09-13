# frozen_string_literal: true

module Orders
  # Starts a provider attempt for a non-event billing purchase such as a
  # Messaging credit top-up. It shares the provider adapter and retry boundary
  # without creating an event order or touching Finance ledgers.
  class StartBillingPaymentAttempt < Core::BaseService
    include PaymentAttemptSupport

    MAX_ATTEMPTS = 3

    def initialize(billing_purchase:, buyer:, provider:, payment_method:, idempotency_key:, at: nil)
      @billing_purchase = billing_purchase
      @buyer = buyer
      @provider = provider.to_s.strip.downcase
      @payment_method = payment_method.to_s.strip.downcase
      @raw_idempotency_key = idempotency_key
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

      provider_result = create_with_provider(adapter.value, state.fetch(:payment))
      persist_provider_result(state.fetch(:payment).id, provider_result)
    # Keep typed abort translation aligned with StartPaymentAttempt; both
    # coordinators expose provider and retry failures as Result values.
    rescue PaymentAttemptSupport::AttemptAbort => error
      failure(error.business_error)
    rescue ArgumentError
      failure(payment_error(:invalid_idempotency_key, code: "invalid_idempotency_key"))
    rescue ActiveRecord::RecordNotFound
      failure(payment_error(:payment_attempt_unavailable, code: "payment_attempt_unavailable", status: :conflict))
    rescue ActiveRecord::RecordNotUnique
      failure(payment_error(:payment_idempotency_conflict, code: "payment_idempotency_conflict", status: :conflict))
    rescue ActiveRecord::RecordInvalid => error
      failure(payment_error(:provider_result_invalid, code: "provider_result_invalid", status: :unprocessable_entity,
        errors: error.record.errors.to_hash))
    end

    private

    attr_reader :billing_purchase, :buyer, :provider, :payment_method, :raw_idempotency_key,
                :idempotency_key, :now

    def resolve_adapter
      resolve_payment_adapter(currency: billing_purchase.currency)
    end

    def reserve_attempt!(adapter)
      # Reserve the attempt under the billing-purchase lock, then perform the
      # provider call after the transaction commits so network latency never
      # extends the database lock or lets a retry create a second attempt.
      state = {}
      ActiveRecord::Base.transaction do
        purchase = BillingPurchase.lock.find(billing_purchase.id)
        validate_purchase!(purchase)
        existing = purchase.payments.lock.find_by(idempotency_key:)
        state[:result] = replay_or_conflict(existing, purchase) if existing
        next if state[:result]

        attempts = purchase.payments.lock.order(:attempt_number).to_a
        abort_with(payment_error(:payment_attempt_limit_reached, code: "payment_attempt_limit_reached", status: :too_many_requests)) if attempts.length >= MAX_ATTEMPTS
        superseded = attempts.reverse.find(&:current?)
        superseded&.update!(superseded_at: now)
        state[:payment] = build_payment(purchase, adapter, attempts.length + 1)
        state[:payment].save!
        purchase.update!(status: "pending_payment") if purchase.status == "created"
      end
      state
    end

    def validate_purchase!(purchase)
      abort_with(payment_error(:billing_purchase_closed, code: "billing_purchase_closed", status: :conflict)) if purchase.closed? || purchase.paid?
      abort_with(payment_error(:billing_purchase_expired, code: "billing_purchase_expired", status: :conflict)) if purchase.expires_at <= now
    end

    def replay_or_conflict(existing, purchase)
      return success(existing) if existing.billing_purchase_id == purchase.id && existing.provider == provider &&
        existing.payment_method == payment_method && existing.amount_minor == purchase.amount_minor &&
        existing.currency == purchase.currency && existing.billing_purchase_price_digest == purchase.price_digest

      abort_with(payment_error(:payment_idempotency_conflict, code: "payment_idempotency_conflict", status: :conflict))
    end

    def build_payment(purchase, adapter, attempt_number)
      Orders::Payment.new(
        billing_purchase: purchase, attempt_number:, provider:, payment_method:, status: "created",
        amount_minor: purchase.amount_minor, currency: purchase.currency,
        billing_purchase_price_digest: purchase.price_digest, buyer_fee_minor: 0, organizer_fee_minor: 0,
        idempotency_key:, settlement_grace_minutes: adapter.settlement_grace_minutes,
        settlement_grace_expires_at: purchase.expires_at + adapter.settlement_grace_minutes.minutes
      )
    end

    def create_with_provider(adapter, payment)
      result = adapter.create(
        payment_id: payment.id, billing_purchase_id: payment.billing_purchase_id,
        provider: payment.provider, payment_method: payment.payment_method,
        amount_minor: payment.amount_minor, currency: payment.currency,
        idempotency_key: payment.idempotency_key, email: buyer.email, phone_number: buyer.phone,
        expires_at: billing_purchase.expires_at
      )
      result.is_a?(Payments::Providers::Result) ? result : Payments::Providers::Result.from_provider_response(result)
    rescue StandardError
      Payments::Providers::Result.unknown(raw_status: "provider_exception")
    end

    def persist_provider_result(payment_id, result)
      payment = Orders::Payment.lock.find(payment_id)
      payment.update!(
        status: payment_status_for(result), provider_reference: result.provider_reference,
        failure_code: result.failure_code, provider_fee_minor: result.provider_fee_minor,
        provider_fee_currency: result.provider_fee_currency, checkout_url: result.checkout_url,
        raw_status: result.raw_status.presence || result.status
      )
      success(payment.reload)
    rescue ActiveRecord::RecordInvalid
      recover_invalid_provider_result(payment:, result:)
    end
  end
end
