# frozen_string_literal: true

module Marketing
  module OutboxHandlers
    # Closes only Marketing placements for failed/reversed billing evidence.
    class BillingPaymentLifecycle < Core::BaseService
      include BillingPaymentSupport

      def initialize(event:)
        @event = event
      end

      def call
        payload = event.payload
        return success(nil) if source_disposition(payload) == :other

        placement = ActiveRecord::Base.transaction do
          current, purchase, payment = resolve_billing_records!(payload)
          if event.event_type.ends_with?("failed")
            raise mismatch_error unless payment.status == "failed"
          else
            raise mismatch_error unless purchase.status == "reversed" || payment.status == "reversed"
          end
          next current if current.status.in?(%w[failed cancelled completed])

          previous_status = current.status
          current.update!(status: "failed", failure_code: event.event_type.split(".").last)
          audit_transition!(
            current, actor: Core::User.find_by(id: purchase.requested_by_id), from: previous_status, to: "failed",
            action: "marketing.featured_placement.payment_#{event.event_type.split('.').last}",
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

      attr_reader :event
    end
  end
end
