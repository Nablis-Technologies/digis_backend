# frozen_string_literal: true

module Admin
  module Messaging
    # Admin-only entry point for audited manual credit corrections. The command
    # appends ledger evidence and never edits a prior balance entry in place.
    class CreditAdjustmentsController < Admin::ApplicationController
      include Core::CommandResponse

      before_action :ensure_idempotency_key_present

      def create
        organization = ::Organizations::Organization.find(params[:organization_id])
        account = ::Messaging::CreditAccount.find_by!(organization:, channel: adjustment_params[:channel])
        authorize ::Messaging::CreditLedgerEntry.new, :create?, policy_class: ::Admin::Messaging::CreditAdjustmentPolicy
        result = ::Messaging::CreditAccounts::Adjust.call(
          account:, organization:, quantity: adjustment_params[:quantity].to_i,
          actor: current_user, reason: adjustment_params[:reason], idempotency_key:
        )
        render_service_result(
          result, serializer_options: { serializer: ::Messaging::CreditLedgerEntrySerializer }
        )
      end

      private

      def adjustment_params
        params.require(:credit_adjustment).permit(:channel, :quantity, :reason)
      end
    end
  end
end
