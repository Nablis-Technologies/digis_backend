# frozen_string_literal: true

module Admin
  module Marketplace
    # Platform payout operations remain separate from the seller API. Admins
    # can dispatch or reconcile a payout, but the provider command still owns
    # reserve, idempotency, and append-only ledger invariants.
    class SellerPayoutsController < Admin::ApplicationController
      include Core::CommandResponse

      before_action :ensure_idempotency_key_present, only: %i[dispatch_payout reconcile]
      before_action :load_payout, only: %i[show dispatch_payout reconcile]

      def index
        @clazz = ::Marketplace::SellerPayout
        authorize @clazz.new, :index?, policy_class: ::Marketplace::SellerPayoutPolicy
        payouts = policy_scope(@clazz, policy_scope_class: ::Marketplace::SellerPayoutPolicy::Scope)
          .order(requested_at: :desc)
        render_success(data: payouts, serializer_options: { serializer: ::Marketplace::SellerPayoutSerializer })
      end

      def show
        authorize @payout, :show?, policy_class: ::Marketplace::SellerPayoutPolicy
        render_success(data: @payout, serializer_options: { serializer: ::Marketplace::SellerPayoutSerializer })
      end

      def dispatch_payout
        authorize @payout, :dispatch?, policy_class: ::Marketplace::SellerPayoutPolicy
        adapter = payout_adapter
        return if performed?

        result = ::Marketplace::DispatchSellerPayout.call(payout: @payout, adapter: adapter)
        render_service_result(result, serializer_options: { serializer: ::Marketplace::SellerPayoutSerializer })
      end

      def reconcile
        authorize @payout, :reconcile?, policy_class: ::Marketplace::SellerPayoutPolicy
        adapter = payout_adapter
        return if performed?

        result = ::Marketplace::ReconcileSellerPayout.call(payout: @payout, adapter: adapter)
        render_service_result(result, serializer_options: { serializer: ::Marketplace::SellerPayoutSerializer })
      end

      private

      def load_payout
        @payout = ::Marketplace::SellerPayout.includes(:seller_payout_account).find(params[:id])
      end

      def payout_adapter
        provider = params[:provider].presence || @payout.provider
        ::Marketplace::PayoutProviders::Registry.fetch(provider)
      rescue KeyError
        render_error(
          I18n.t("marketplace.resale.errors.seller_payout_provider_unavailable"),
          status: :unprocessable_entity, code: "seller_payout_provider_unavailable"
        )
        nil
      end
    end
  end
end
