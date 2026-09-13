# frozen_string_literal: true

module Finance
  # Organization payout-destination API. Sensitive beneficiary values enter
  # only the registration command and never cross the serializer boundary.
  class PayoutAccountsController < Finance::ApplicationController
    include Core::CommandResponse
    include Core::Pagination

    before_action :ensure_idempotency_key_present,
                  only: %i[create verify set_default suspend close]
    before_action :load_organization
    before_action :load_account, only: %i[verify set_default suspend close]

    def index
      sample = PayoutAccount.new(organization: @organization)
      authorize sample, :index?
      @clazz = PayoutAccount
      accounts = policy_scope(PayoutAccount)
        .where(organization: @organization)
      accounts = apply_ordering(accounts)
      total_count = accounts.count if paginated_request?
      accounts = paginated_request? ? apply_pagination(accounts) : accounts.limit(default_per_page)
      pagination = paginated_request? ? pagination_metadata(total_count) : nil
      render_success(
        data: accounts,
        serializer_options: { serializer: PayoutAccountSerializer },
        pagination:
      )
    end

    def create
      account = PayoutAccount.new(organization: @organization)
      authorize account, :create?
      adapter = payout_adapter(payout_account_params.require(:provider))
      return if performed?

      result = PayoutAccounts::Register.call(
        organization: @organization,
        type: payout_account_params.require(:type),
        provider: payout_account_params.require(:provider),
        bank_slug: payout_account_params.require(:bank_slug),
        account_number: payout_account_params.require(:account_number),
        account_name: payout_account_params[:account_name],
        account_label: payout_account_params[:account_label],
        actor: current_user,
        adapter:,
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: PayoutAccountSerializer }
      )
    end

    def verify
      authorize @account, :verify?
      render_account_command(
        PayoutAccounts::Verify.call(
          account: @account, actor: current_user,
          reason: params.require(:reason),
          evidence_reference: params.require(:evidence_reference),
          idempotency_key:
        )
      )
    end

    def set_default
      authorize @account, :set_default?
      render_account_command(
        PayoutAccounts::SetDefault.call(account: @account, actor: current_user, idempotency_key:)
      )
    end

    def suspend
      authorize @account, :suspend?
      render_account_command(
        PayoutAccounts::Suspend.call(
          account: @account, actor: current_user, reason: params.require(:reason), idempotency_key:
        )
      )
    end

    def close
      authorize @account, :close?
      render_account_command(
        PayoutAccounts::Close.call(
          account: @account, actor: current_user, reason: params.require(:reason), idempotency_key:
        )
      )
    end

    private

    def load_organization
      @organization = Organizations::Organization.find(params[:organization_id])
    end

    def load_account
      @account = @organization.finance_payout_accounts.find(params[:id])
    end

    def payout_account_params
      params.require(:payout_account).permit(
        :type, :provider, :bank_slug, :account_number, :account_name, :account_label
      )
    end

    def allowed_order_columns
      %w[id provider status created_at updated_at]
    end

    def payout_adapter(provider)
      PayoutProviders::Registry.fetch(provider)
    rescue KeyError
      render_error(
        I18n.t("finance.errors.payout_account_provider_unavailable"),
        code: "payout_account_provider_unavailable", status: :unprocessable_entity
      )
      nil
    end

    def render_account_command(result)
      render_service_result(
        result,
        serializer_options: { serializer: PayoutAccountSerializer }
      )
    end
  end
end
