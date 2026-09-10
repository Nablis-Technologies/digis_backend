# frozen_string_literal: true

module Admin
  module Marketplace
    # Admin review surface for seller payout destinations. It exposes only safe
    # metadata and delegates the state transition to the audited command.
    class SellerPayoutAccountsController < Admin::ApplicationController
      include Core::CommandResponse

      before_action :ensure_idempotency_key_present, only: :verify
      before_action :load_account, only: %i[show verify]

      def index
        @clazz = ::Marketplace::SellerPayoutAccount
        authorize @clazz.new, :index?, policy_class: ::Admin::Marketplace::SellerPayoutAccountPolicy
        accounts = policy_scope(@clazz).order(created_at: :desc)
        render_success(data: accounts, serializer_options: {
          serializer: ::Marketplace::SellerPayoutAccountSerializer
        })
      end

      def show
        authorize @account, :show?, policy_class: ::Admin::Marketplace::SellerPayoutAccountPolicy
        render_success(data: @account, serializer_options: {
          serializer: ::Marketplace::SellerPayoutAccountSerializer
        })
      end

      def verify
        authorize @account, :verify?, policy_class: ::Admin::Marketplace::SellerPayoutAccountPolicy
        result = ::Marketplace::SellerPayoutAccounts::Verify.call(
          account: @account,
          actor: current_user,
          reason: params[:reason],
          evidence_reference: params[:evidence_reference],
          idempotency_key:
        )
        render_service_result(result, serializer_options: {
          serializer: ::Marketplace::SellerPayoutAccountSerializer
        })
      end

      private

      def load_account
        @account = ::Marketplace::SellerPayoutAccount.find(params[:id])
      end
    end
  end
end
