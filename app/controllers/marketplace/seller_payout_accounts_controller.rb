# frozen_string_literal: true

module Marketplace
  # Seller destination API. Provider tokenization is injected through the
  # registry, while VerifyPayoutAccount remains the sole mutation command.
  class SellerPayoutAccountsController < Marketplace::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present, only: :create

    def index
      @clazz = SellerPayoutAccount
      authorize SellerPayoutAccount.new(user: current_user), :index?
      accounts = policy_scope(@clazz).order(created_at: :desc)
      render_success(data: accounts, serializer_options: { serializer: SellerPayoutAccountSerializer })
    end

    def create
      account = SellerPayoutAccount.new(user: current_user)
      authorize account, :create?
      provider = payout_account_params.require(:provider).to_s.downcase
      adapter = PayoutProviders::Registry.fetch(provider)
      result = VerifyPayoutAccount.call(
        user: current_user,
        type: payout_account_params.require(:type),
        provider:,
        account_details: payout_account_params[:account_details]&.to_h || {},
        account_label: payout_account_params[:account_label],
        holder_name: payout_account_params[:holder_name],
        adapter:,
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: SellerPayoutAccountSerializer }
      )
    rescue KeyError
      render_error(
        I18n.t("marketplace.resale.errors.payout_account_provider_unavailable"),
        status: :unprocessable_entity, code: "payout_account_provider_unavailable"
      )
    end

    private

    def payout_account_params
      params.require(:payout_account).permit(
        :type, :provider, :account_label, :holder_name, account_details: {}
      )
    end
  end
end
