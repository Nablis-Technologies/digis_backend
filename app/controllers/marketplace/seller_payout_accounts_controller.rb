# frozen_string_literal: true

module Marketplace
  # Seller destination API. Sensitive beneficiary values enter only the
  # registration command; the response remains a safe metadata projection.
  class SellerPayoutAccountsController < Marketplace::ApplicationController
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present, only: %i[create set_default]
    before_action :load_account, only: :set_default

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
        bank_code: payout_account_params.require(:bank_code),
        account_number: payout_account_params.require(:account_number),
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

    def set_default
      authorize @account, :set_default?
      render_service_result(
        SellerPayoutAccounts::SetDefault.call(
          account: @account, actor: current_user, idempotency_key:
        ),
        serializer_options: { serializer: SellerPayoutAccountSerializer }
      )
    end

    private

    def payout_account_params
      params.require(:payout_account).permit(
        :type, :provider, :bank_code, :account_number, :account_label, :holder_name
      )
    end

    def load_account
      @account = policy_scope(SellerPayoutAccount).find(params[:id])
    end
  end
end
