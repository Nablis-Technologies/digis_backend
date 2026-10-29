# frozen_string_literal: true

module Admin
  module Orders
    class RefundResolutionsController < Admin::ApplicationController
      include Core::CommandResponse

      before_action :ensure_idempotency_key_present, only: :resolve_manual
      before_action :load_refund

      def resolve_manual
        authorize @refund, :resolve_manual?, policy_class: Admin::Orders::RefundResolutionPolicy
        attributes = resolution_params
        result = ::Orders::ResolveManualBillingPurchaseRefund.call(
          refund: @refund, actor: current_user, reason: attributes[:reason],
          evidence_reference: attributes[:evidence_reference], idempotency_key:
        )
        return render_business_error(result.error) if result.failure?

        refund = result.value.refund
        render_success(data: {
          id: refund.id, status: refund.status, amount_minor: refund.amount_minor,
          currency: refund.currency, type: refund.type, manual_resolved_at: refund.manual_resolved_at,
          replayed: result.value.replayed
        })
      end

      private

      def load_refund
        @refund = ::Orders::Refund.find(params[:id])
      end

      def resolution_params
        params.require(:resolution).permit(:reason, :evidence_reference)
      end
    end
  end
end
