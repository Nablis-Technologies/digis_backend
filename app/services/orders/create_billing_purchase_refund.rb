# frozen_string_literal: true

module Orders
  # Creates a durable, bounded refund obligation for a paid non-event purchase.
  # Provider submission is dispatched only after this transaction commits.
  class CreateBillingPurchaseRefund < Core::BaseService
    Result = Data.define(:refund, :replayed)

    def initialize(payment:, billing_purchase:, amount_minor:, reason_code:, actor: nil,
      idempotency_key:, at: Time.current)
      @payment_id = payment.id
      @billing_purchase_id = billing_purchase.id
      @amount_minor = amount_minor
      @reason_code = reason_code.to_s.strip.downcase
      @actor = actor
      @raw_idempotency_key = idempotency_key
      @at = at.to_time.utc
    end

    def call
      key = Core::IdempotencyKey.new(raw_idempotency_key)
      return failure(error(:invalid_refund, status: :unprocessable_entity)) unless valid_amount?

      result = ActiveRecord::Base.transaction do
        payment = Orders::Payment.lock.find(payment_id)
        purchase = Orders::BillingPurchase.lock.find(billing_purchase_id)
        command_key = refund_key(key)
        existing = Orders::Refund.lock.find_by(idempotency_key: command_key)
        if existing
          next replay_or_conflict(existing, payment:, purchase:)
        end

        validate_source!(payment, purchase)
        prior_refunds = Orders::Refund.where(payment_id: payment.id).order(:id).lock.to_a
        refundable_minor = payment.amount_minor - prior_refunds
          .select { |refund| Orders::Refund::OUTSTANDING_STATUSES.include?(refund.status) }
          .sum(&:amount_minor)
        unless amount_minor <= refundable_minor
          next failure(error(:refund_amount_exceeded, status: :conflict))
        end

        refund = Orders::Refund.create!(
          payment:, billing_purchase: purchase, type: "billing_purchase_refund",
          idempotency_key: command_key, amount_minor:, currency: purchase.currency,
          status: "created", reason_code:, reason: I18n.t("orders.refunds.billing_purchase_reasons.#{reason_code}"),
          created_at: at, updated_at: at
        )
        publish_created!(refund, purchase)
        record_audit!(refund, purchase)
        success(Result.new(refund, false))
      end
      result
    rescue ArgumentError
      failure(error(:invalid_idempotency_key, status: :bad_request))
    rescue ActiveRecord::RecordNotFound
      failure(error(:refund_source_not_found, status: :not_found))
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:invalid_refund, errors: exception.record.errors.to_hash))
    rescue ActiveRecord::RecordNotUnique
      replay_after_conflict
    rescue Core::Audit::Record::ReplayConflict
      failure(error(:idempotency_conflict, status: :conflict))
    rescue Core::Error => exception
      failure(exception)
    end

    private

    attr_reader :payment_id, :billing_purchase_id, :amount_minor, :reason_code, :actor,
                :raw_idempotency_key, :at

    def valid_amount?
      amount_minor.is_a?(Integer) && amount_minor.positive? &&
        Orders::Refund::BILLING_PURCHASE_REFUND_REASONS.include?(reason_code)
    end

    def refund_key(key = Core::IdempotencyKey.new(raw_idempotency_key))
      Core::KeyedDigest.digest(
        namespace: "orders-billing-purchase-refund/#{billing_purchase_id}", value: key.to_s
      )
    end

    def validate_source!(payment, purchase)
      valid = payment.billing_purchase_id == purchase.id && payment.status == "succeeded" &&
        payment.accepted_at.present? && purchase.status == "paid" &&
        payment.amount_minor == purchase.amount_minor && payment.currency == purchase.currency &&
        payment.billing_purchase_price_digest == purchase.price_digest
      raise error(:refund_source_not_paid, status: :conflict) unless valid
    end

    def replay_or_conflict(refund, payment:, purchase:)
      same = refund.payment_id == payment.id && refund.billing_purchase_id == purchase.id &&
        refund.amount_minor == amount_minor && refund.currency == purchase.currency &&
        refund.reason_code == reason_code
      return failure(error(:idempotency_conflict, status: :conflict)) unless same

      success(Result.new(refund, true))
    end

    def publish_created!(refund, purchase)
      result = Core::Outbox::Publish.call(
        topic: "orders", event_type: "orders.refund.created", aggregate: refund,
        payload: {
          refund_id: refund.id, payment_id: refund.payment_id,
          billing_purchase_id: purchase.id, refund_type: refund.type,
          amount_minor: refund.amount_minor, currency: refund.currency
        },
        idempotency_key: "orders-refund-created-#{refund.id}"
      )
      raise result.error if result.failure?
    end

    def record_audit!(refund, purchase)
      result = Core::Audit::Record.call(
        audit_key: "orders-billing-purchase-refund-created-#{refund.idempotency_key}",
        action: "orders.billing_purchase_refund.created", auditable_type: refund.class.name,
        auditable_id: refund.id, actor_type: actor&.class&.name, actor_id: actor&.id,
        audited_changes: { status: [ nil, "created" ] },
        metadata: {
          billing_purchase_id: purchase.id, payment_id: refund.payment_id,
          amount_minor: refund.amount_minor, currency: refund.currency,
          reason_code: refund.reason_code, request_digest: request_digest
        }
      )
      raise result.error if result.failure?
    end

    def request_digest
      Core::KeyedDigest.digest(
        namespace: "orders-billing-purchase-refund-request",
        value: ActiveSupport::JSON.encode(
          payment_id:, billing_purchase_id:, amount_minor:, reason_code:, currency: "ETB"
        )
      )
    end

    def replay_after_conflict
      refund = Orders::Refund.find_by(idempotency_key: refund_key)
      return failure(error(:idempotency_conflict, status: :conflict)) unless refund

      purchase = Orders::BillingPurchase.find(billing_purchase_id)
      payment = Orders::Payment.find(payment_id)
      replay_or_conflict(refund, payment:, purchase:)
    end

    def error(key, status: :unprocessable_entity, errors: nil)
      Core::BusinessError.new(I18n.t("orders.refunds.errors.#{key}"), code: key.to_s, status:, errors:)
    end
  end
end
