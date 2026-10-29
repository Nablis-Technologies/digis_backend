# frozen_string_literal: true

module Marketing
  module OutboxHandlers
    # Activates only from a committed, typed Orders payment acceptance event.
    class BillingPaymentAccepted < Core::BaseService
      include BillingPaymentSupport

      def initialize(event:, at: Time.current)
        @event = event
        @at = at.to_time.utc
      end

      def call
        payload = event.payload
        return success(nil) if source_disposition(payload) == :other

        placement = ActiveRecord::Base.transaction do
          current, purchase, payment = resolve_billing_records!(payload)
          unless purchase.status == "paid" && payment.accepted? && payment.status == "succeeded"
            raise mismatch_error
          end
          next current if current.status != "pending_payment"

          next_status = if current.ends_at <= at
            "completed"
          elsif current.starts_at <= at
            "active"
          else
            "scheduled"
          end
          current.update!(status: next_status, completed_at: (at if next_status == "completed"))
          audit_transition!(
            current, actor: Core::User.find_by(id: purchase.requested_by_id), from: "pending_payment", to: next_status,
            action: "marketing.featured_placement.payment_accepted",
            metadata: { billing_purchase_id: purchase.id, payment_id: payment.id }
          )
          current
        end
        success(placement)
      rescue ActiveRecord::RecordInvalid => exception
        failure(Core::BusinessError.new(
          I18n.t("marketing.featured_placements.errors.billing_payment_mismatch"),
          code: "billing_payment_mismatch", status: :conflict, errors: exception.record.errors.to_hash
        ))
      rescue Core::Error => exception
        failure(exception)
      end

      private

      attr_reader :event, :at
    end
  end
end
