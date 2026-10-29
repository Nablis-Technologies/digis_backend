# frozen_string_literal: true

module Messaging
  # Converts one accepted Orders billing payment into one immutable credit grant.
  class GrantTopUpCredits < Core::BaseService
    def initialize(top_up:, payment:)
      @top_up = top_up
      @payment = payment
    end

    def call
      ActiveRecord::Base.transaction do
        top_up = CreditTopUp.lock.find(@top_up.id)
        payment = Orders::Payment.lock.find(@payment.id)
        # A late accepted payment may arrive after the payment reversal was
        # recorded. Refund evidence makes that terminal state authoritative;
        # acknowledge it instead of retrying a grant that must never be issued.
        return success(top_up) if top_up.status == "reversed" && refund_evidence?(payment, top_up)
        return failure(error(:top_up_payment_mismatch, status: :conflict)) unless payment_matches?(top_up, payment)
        return failure(error(:top_up_payment_mismatch, status: :conflict)) if top_up.status.in?(%w[cancelled failed reversed])

        account = CreditAccount.lock.find(top_up.credit_account_id)
        entry = account.ledger_entries.find_by(entry_type: "top_up", reference_type: "Messaging::CreditTopUp", reference_id: top_up.id)
        return success(top_up) if top_up.status == "paid" && entry

        unless entry
          entry = CreditLedgerEntry.create!(
            credit_account: account, rate_version: top_up.rate_version,
            entry_type: "top_up", quantity: top_up.quantity, available_delta: top_up.quantity,
            reference_type: "Messaging::CreditTopUp", reference_id: top_up.id,
            idempotency_key_digest: Core::KeyedDigest.digest(
              namespace: "messaging-credit-grant", value: top_up.id
            ), metadata: { "payment_id" => payment.id.to_s }
          )
        end
        top_up.update!(status: "paid", accepted_payment: payment, provider_reference: payment.provider_reference)
        success(top_up)
      end
    rescue ActiveRecord::RecordNotFound
      failure(error(:top_up_payment_mismatch, status: :conflict))
    rescue ActiveRecord::RecordInvalid => exception
      failure(error(:invalid_credit_operation, errors: exception.record.errors.to_hash))
    end

    private

    def payment_matches?(top_up, payment)
      payment.accepted? && payment.billing_purchase_id == top_up.orders_billing_purchase_id &&
        payment.amount_minor == top_up.amount_minor && payment.currency == top_up.currency &&
        payment.billing_purchase_price_digest == top_up.price_digest &&
        payment.billing_purchase&.organization_id == top_up.organization_id
    end

    def refund_evidence?(payment, top_up)
      return false unless payment.billing_purchase_id == top_up.orders_billing_purchase_id

      Orders::Refund.where(
        payment_id: payment.id, type: "payment_reversal", status: %w[created pending_funds processing succeeded]
      ).exists? ||
        top_up.credit_account.ledger_entries.where(
          entry_type: "refund", reference_type: "Messaging::CreditTopUp", reference_id: top_up.id
        ).exists?
    end

    def error(key, status: :unprocessable_entity, errors: nil)
      Core::BusinessError.new(I18n.t("messaging.errors.#{key}"), code: key.to_s, status:, errors:)
    end
  end
end
