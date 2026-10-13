# frozen_string_literal: true

module Marketing
  module OutboxHandlers
    module BillingPaymentSupport
      private

      def source_disposition(payload)
        source_type = payload["source_type"]
        return :owned if source_type == "Marketing::FeaturedPlacement"
        return :other if Orders::BillingPurchase::SOURCE_TYPES.include?(source_type)

        raise mismatch_error
      end

      def mismatch_error
        Core::BusinessError.new(
          I18n.t("marketing.featured_placements.errors.billing_payment_mismatch"),
          code: "billing_payment_mismatch", status: :conflict
        )
      end

      def resolve_billing_records!(payload)
        placement = Marketing::FeaturedPlacement.lock.find(payload.fetch("source_id"))
        purchase = Orders::BillingPurchase.lock.find(payload.fetch("billing_purchase_id"))
        payment = Orders::Payment.lock.find(payload.fetch("payment_id"))
        unless purchase.source_type == "Marketing::FeaturedPlacement" && purchase.source_id == placement.id &&
            payment.billing_purchase_id == purchase.id && payment.amount_minor == placement.amount_minor &&
            payment.currency == placement.currency && purchase.amount_minor == placement.amount_minor &&
            purchase.currency == placement.currency && purchase.price_digest == placement.price_digest
          raise mismatch_error
        end

        [ placement, purchase, payment ]
      rescue KeyError, ActiveRecord::RecordNotFound
        raise mismatch_error
      end

      def audit_transition!(placement, actor:, from:, to:, action:, metadata: {})
        result = Core::Audit::Record.call(
          audit_key: "#{action}-#{placement.id}", action:, auditable_type: placement.class.name,
          auditable_id: placement.id, actor_type: actor&.class&.name, actor_id: actor&.id,
          audited_changes: { status: [ from, to ] }, metadata: metadata.compact
        )
        raise result.error if result.failure?
      end
    end
  end
end
