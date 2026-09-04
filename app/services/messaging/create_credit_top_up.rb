# frozen_string_literal: true

require "digest"

module Messaging
  # Creates an immutable credit purchase intent, then delegates payment I/O to
  # Orders. Credits are granted only by the accepted-payment outbox handler.
  class CreateCreditTopUp < Core::BaseService
    def initialize(organization:, requester:, channel:, quantity:, currency:, provider:, payment_method:,
      country_code: nil, idempotency_key:, at: Time.current)
      @organization = organization
      @requester = requester
      @channel = channel.to_s.strip.downcase
      @quantity = quantity
      @currency = currency.to_s.strip.upcase
      @provider = provider.to_s.strip.downcase
      @payment_method = payment_method.to_s.strip.downcase
      @country_code = country_code.to_s.strip.upcase.presence
      @raw_idempotency_key = idempotency_key
      @at = at.to_time
    end

    def call
      return failure(error(:unauthorized, status: :forbidden)) unless authorized?
      return failure(error(:invalid_credit_quantity)) unless @quantity.is_a?(Integer) && @quantity.positive?

      key = Core::IdempotencyKey.new(@raw_idempotency_key)
      key_digest = Core::KeyedDigest.digest(namespace: "messaging-credit-top-up", value: key.to_s)
      request_digest = request_digest_for
      existing = CreditTopUp.find_by(organization: @organization, idempotency_key_digest: key_digest)
      if existing
        # The request digest binds the key to its quoted inputs. A matching
        # retry may reuse the purchase, but a changed request is a conflict.
        return failure(error(:credit_idempotency_conflict, status: :conflict)) unless existing.request_digest == request_digest

        existing_payment = existing.billing_purchase&.payments&.order(:attempt_number)&.last
        return success(top_up: existing, payment: payment_summary(existing_payment)) if existing_payment
      end

      top_up = existing || begin
        estimate = EstimateCreditTopUp.call(
          organization: @organization, channel: @channel, quantity: @quantity,
          currency: @currency, country_code: @country_code, at: @at
        )
        return failure(estimate.error) if estimate.failure?

        persist_top_up!(estimate.value, key_digest, request_digest)
      end
      payment = Orders::StartBillingPaymentAttempt.call(
        billing_purchase: top_up.billing_purchase, buyer: @requester,
        provider: @provider, payment_method: @payment_method,
        idempotency_key: "messaging-top-up-payment-#{key}", at: @at
      )
      return failure(payment.error) if payment.failure?

      failed = payment.value.status == "failed"
      persisted_top_up = persist_payment_state!(top_up, payment.value, failed:)
      success(top_up: persisted_top_up, payment: payment_summary(payment.value))
    rescue ArgumentError
      failure(error(:invalid_idempotency_key))
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:invalid_credit_operation, errors: exception.record.errors.to_hash))
    rescue ActiveRecord::RecordNotUnique
      failure(error(:credit_idempotency_conflict, status: :conflict))
    end

    private

    def authorized?
      @requester&.super_admin? || @requester&.has_role_in?(@organization, :owner, :admin, :manager)
    end

    def persist_top_up!(estimate, key_digest, request_digest)
      # Top-up, billing purchase, and their source link commit together so an
      # accepted payment can never point at a half-created credit intent.
      ActiveRecord::Base.transaction do
        account = CreditAccount.create_or_find_by!(organization: @organization, channel: @channel)
        top_up = CreditTopUp.create!(
          organization: @organization, credit_account: account,
          rate_version: estimate.fetch(:rate_version), channel: @channel,
          quantity: @quantity, currency: @currency, amount_minor: estimate.fetch(:amount_minor),
          price_digest: estimate.fetch(:price_digest), status: "created",
          idempotency_key_digest: key_digest, request_digest:
        )
        purchase = Orders::BillingPurchase.create!(
          organization: @organization, requested_by: @requester,
          kind: "messaging_credit_top_up", source_type: "Messaging::CreditTopUp", source_id: top_up.id,
          currency: @currency, amount_minor: top_up.amount_minor, price_digest: top_up.price_digest,
          status: "created", idempotency_key_digest: key_digest,
          expires_at: @at + 30.minutes
        )
        top_up.update!(billing_purchase: purchase)
        top_up
      end
    end

    def request_digest_for
      Digest::SHA256.hexdigest(ActiveSupport::JSON.encode(
        channel: @channel, quantity: @quantity, currency: @currency,
        country_code: @country_code, provider: @provider, payment_method: @payment_method
      ))
    end

    def persist_payment_state!(top_up, payment, failed:)
      # Lock both aggregates before recording provider state; webhook/retry
      # workers must observe one coherent top-up and purchase status.
      ActiveRecord::Base.transaction do
        locked_top_up = CreditTopUp.lock.find(top_up.id)
        locked_purchase = Orders::BillingPurchase.lock.find(locked_top_up.orders_billing_purchase_id)
        locked_top_up.update!(
          status: failed ? "failed" : "pending_payment",
          provider_reference: payment.provider_reference
        )
        locked_purchase.update!(status: "failed") if failed
        locked_top_up.reload
      end
    end

    def payment_summary(payment)
      return nil unless payment

      payment.slice(:id, :status, :provider, :provider_reference, :checkout_url, :amount_minor, :currency)
    end

    def error(key, status: :unprocessable_entity, errors: nil)
      Core::BusinessError.new(I18n.t("messaging.errors.#{key}"), code: key.to_s, status:, errors:)
    end
  end
end
