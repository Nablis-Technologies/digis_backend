# frozen_string_literal: true

module Messaging
  # Applies failed/reversed billing evidence without deleting a prior grant.
  class ResolveTopUpPayment < Core::BaseService
    def initialize(top_up:, payment:, outcome:)
      @top_up = top_up
      @payment = payment
      @outcome = outcome.to_s
    end

    def call
      ActiveRecord::Base.transaction do
        top_up = CreditTopUp.lock.find(@top_up.id)
        payment = Orders::Payment.lock.find(@payment.id)
        return failure(error(:top_up_payment_mismatch, status: :conflict)) unless payment.billing_purchase_id == top_up.orders_billing_purchase_id
        return resolve_failure(top_up, payment) if @outcome == "failed"
        return reverse_grant(top_up) if @outcome == "reversed"

        failure(error(:invalid_credit_operation))
      end
    rescue ActiveRecord::RecordNotFound
      failure(error(:top_up_payment_mismatch, status: :conflict))
    end

    private

    def resolve_failure(top_up, payment)
      # A stale failure must not overwrite a terminal top-up or steal a later
      # attempt's lifecycle; the current attempt remains the source of truth.
      return success(top_up) if top_up.status.in?(%w[failed paid cancelled reversed])
      return success(top_up) if payment.superseded_at.present? || another_attempt_pending?(top_up, payment)

      top_up.update!(status: "failed")
      success(top_up)
    end

    def another_attempt_pending?(top_up, payment)
      top_up.billing_purchase.payments.where(status: %w[created processing succeeded])
        .where.not(id: payment.id).exists?
    end

    def reverse_grant(top_up)
      # Reversal is append-only: even if credits were already consumed, record
      # the negative grant evidence and let the balance become negative rather
      # than silently dropping a provider chargeback.
      return success(top_up) if top_up.status == "reversed"
      return success(top_up) if top_up.accepted_payment_id.present? && top_up.accepted_payment_id != @payment.id

      unless top_up.status == "paid"
        top_up.update!(status: "reversed")
        return success(top_up)
      end

      account = CreditAccount.lock.find(top_up.credit_account_id)
      existing = account.ledger_entries.find_by(entry_type: "refund", reference_type: "Messaging::CreditTopUp", reference_id: top_up.id)
      unless existing
        CreditLedgerEntry.create!(
          credit_account: account, rate_version: top_up.rate_version,
          entry_type: "refund", quantity: top_up.quantity, available_delta: -top_up.quantity,
          reference_type: "Messaging::CreditTopUp", reference_id: top_up.id,
          idempotency_key_digest: Core::KeyedDigest.digest(
            namespace: "messaging-credit-reversal", value: top_up.id
          ), metadata: { "reason" => "billing_payment_reversed", "payment_id" => @payment.id.to_s }
        )
      end
      top_up.update!(status: "reversed")
      success(top_up)
    end

    def error(key, status: :unprocessable_entity)
      Core::BusinessError.new(I18n.t("messaging.errors.#{key}"), code: key.to_s, status:)
    end
  end
end
