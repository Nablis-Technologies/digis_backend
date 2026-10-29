# frozen_string_literal: true

module Finance
  # Appends immutable platform ledger facts for one accepted placement charge
  # or one succeeded billing refund.
  class PostPlatformBillingEntry < Core::BaseService
    def initialize(payment:, billing_purchase:, type:, refund: nil)
      @payment_id = payment.id
      @billing_purchase_id = billing_purchase.id
      @refund_id = refund&.id
      @type = type.to_s
    end

    def call
      entries = ActiveRecord::Base.transaction do
        payment = Orders::Payment.lock.find(payment_id)
        purchase = Orders::BillingPurchase.lock.find(billing_purchase_id)
        raise entry_error(:invalid_source) unless Orders::BillingPurchase::SOURCE_TYPES.include?(purchase.source_type)
        next [] unless purchase.source_type == "Marketing::FeaturedPlacement"

        validate_payment_matches_purchase!(purchase, payment)
        if type == "charge"
          validate_accepted_payment!(purchase, payment)
          charge_entries(purchase, payment)
        elsif type == "refund"
          refund = Orders::Refund.lock.find(refund_id)
          validate_succeeded_refund!(purchase, payment, refund)
          [ create_entry!(purchase:, payment:, refund:, entry_type: "featured_placement_refund", amount_minor: -refund.amount_minor) ]
        else
          raise entry_error(:invalid_entry_type)
        end
      end
      success(entries)
    rescue ActiveRecord::RecordNotFound
      failure(entry_error(:source_not_found, status: :not_found))
    rescue ActiveRecord::RecordInvalid => exception
      failure(entry_error(:invalid_source, errors: exception.record.errors.to_hash))
    rescue Core::Error => exception
      failure(exception)
    end

    private

    attr_reader :payment_id, :billing_purchase_id, :refund_id, :type

    def validate_payment_matches_purchase!(purchase, payment)
      payment_matches = payment.billing_purchase_id == purchase.id &&
        payment.amount_minor == purchase.amount_minor && payment.currency == purchase.currency &&
        payment.billing_purchase_price_digest == purchase.price_digest
      raise entry_error(:payment_source_mismatch) unless payment_matches
    end

    def validate_accepted_payment!(purchase, payment)
      raise entry_error(:payment_not_accepted) unless purchase.status == "paid" &&
        payment.status == "succeeded" && payment.accepted_at.present?
    end

    def validate_succeeded_refund!(purchase, payment, refund)
      valid = refund.status == "succeeded" && refund.type == "billing_purchase_refund" &&
        refund.billing_purchase_id == purchase.id && refund.payment_id == payment.id &&
        refund.currency == purchase.currency && refund.amount_minor.positive?
      raise entry_error(:refund_not_succeeded) unless valid
    end

    def charge_entries(purchase, payment)
      entries = [ create_entry!(
        purchase:, payment:, entry_type: "featured_placement_charge", amount_minor: purchase.amount_minor
      ) ]
      return entries unless payment.provider_fee_minor&.positive?

      entries << create_entry!(
        purchase:, payment:, entry_type: "provider_fee", amount_minor: -payment.provider_fee_minor
      )
      entries
    end

    def create_entry!(purchase:, payment:, entry_type:, amount_minor:, refund: nil)
      idempotency_key = Core::KeyedDigest.digest(
        namespace: "finance-platform-billing-entry/#{entry_type}", value: refund&.id || payment.id
      )
      entry = Finance::PlatformBillingEntry.create_or_find_by!(idempotency_key:) do |row|
        row.assign_attributes(
          billing_purchase: purchase, payment:, refund:,
          type: entry_type, amount_minor:, currency: purchase.currency
        )
      end
      expected = [ purchase.id, payment.id, refund&.id, entry_type, amount_minor, purchase.currency ]
      actual = [ entry.billing_purchase_id, entry.payment_id, entry.refund_id, entry.type, entry.amount_minor, entry.currency ]
      raise entry_error(:idempotency_conflict, status: :conflict) unless expected == actual

      entry
    end

    def entry_error(key, status: :unprocessable_entity, errors: nil)
      Core::BusinessError.new(
        I18n.t("finance.platform_billing_entries.errors.#{key}"), code: key.to_s, status:, errors:
      )
    end
  end
end
