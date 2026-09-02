# frozen_string_literal: true

module Finance
  # Finance API boundary for organizer reports and platform treasury controls.
  # Organizer writes create payout intents only; dispatch, reconciliation,
  # reserve changes, and no-balance approvals remain permission-gated commands.
  class PayoutsController < Finance::ApplicationController
    include Core::CommandResponse
    include Core::Pagination

    before_action :ensure_idempotency_key_present,
                  only: %i[create dispatch_payout reconcile approve_no_balance_api update_reserve_policy]
    before_action :load_organization, only: %i[index create ledger_entries balance show dispatch_payout reconcile]
    before_action :load_payout, only: %i[show dispatch_payout reconcile approve_no_balance_api]

    def index
      authorize payout_scope_sample, :index?
      @clazz = Finance::Payout
      payouts = policy_scope(Finance::Payout)
        .where(organization: @organization)
        .includes(:payout_account)
      payouts = apply_report_ordering(payouts, requested_at: :desc)
      total_count = payouts.count if paginated_request?
      payouts = paginated_request? ? apply_pagination(payouts) : payouts.limit(default_per_page)
      render_success(
        data: payouts,
        serializer_options: {
          serializer: Finance::PayoutSerializer,
          visible_attributes: Finance::PayoutPolicy::SAFE_FIELDS
        },
        pagination: paginated_request? ? pagination_metadata(total_count) : nil
      )
    end

    def show
      authorize @payout, :show?
      render_success(data: @payout, serializer_options: { serializer: Finance::PayoutSerializer })
    end

    def create
      authorize payout_scope_sample, :create?
      result = Finance::BuildPayout.call(
        organization: @organization,
        currency: payout_params.require(:currency),
        amount_minor: payout_params[:amount_minor],
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: Finance::PayoutSerializer }
      )
    end

    def ledger_entries
      authorize ledger_scope_sample, :index?
      @clazz = Finance::LedgerEntry
      entries = policy_scope(Finance::LedgerEntry)
        .where(organization: @organization)
        .includes(:event)
        .then { |scope| payout_currency.present? ? scope.where(currency: payout_currency) : scope }
      entries = apply_report_ordering(entries, created_at: :desc)
      total_count = entries.count if paginated_request?
      entries = paginated_request? ? apply_pagination(entries) : entries.limit(default_per_page)
      render_success(
        data: entries,
        serializer_options: {
          serializer: Finance::LedgerEntrySerializer,
          visible_attributes: Finance::LedgerEntryPolicy::SAFE_FIELDS
        },
        pagination: paginated_request? ? pagination_metadata(total_count) : nil
      )
    end

    def balance
      authorize ledger_scope_sample, :index?
      result = Finance::BalanceReport.call(organization: @organization, currency: payout_currency)
      render_service_result(result)
    end

    def dispatch_payout
      authorize @payout, :dispatch?
      adapter = payout_adapter
      return if performed?

      result = Finance::DispatchPayout.call(
        payout: @payout,
        adapter:,
        treasury_approval: treasury_approval
      )
      render_service_result(result, serializer_options: { serializer: Finance::PayoutSerializer })
    end

    def reconcile
      authorize @payout, :reconcile?
      adapter = payout_adapter
      return if performed?

      result = Finance::ReconcilePayout.call(payout: @payout, adapter:)
      render_service_result(result, serializer_options: { serializer: Finance::PayoutSerializer })
    end

    def approve_no_balance_api
      authorize @payout, :approve_no_balance_api?
      result = Finance::ApprovePayoutWithoutBalanceApi.call(
        payout: @payout,
        actor: current_user,
        idempotency_key:,
        reason: params.require(:reason)
      )
      render_service_result(result, serializer_options: { serializer: Finance::PayoutSerializer })
    end

    def update_reserve_policy
      policy = Finance::ProviderReservePolicy.new(
        provider: params[:provider], currency: params[:currency]
      )
      authorize policy, :update?, policy_class: Finance::ProviderReservePolicyPolicy
      result = Finance::UpdateProviderReservePolicy.call(
        provider: params[:provider], currency: params[:currency],
        target_minor: params.require(:target_minor), actor: current_user, idempotency_key:
      )
      render_service_result(
        result,
        serializer_options: { serializer: Finance::ProviderReservePolicySerializer }
      )
    end

    private

    def load_organization
      @organization = Organizations::Organization.find(params[:organization_id])
    end

    def load_payout
      scope = @organization ? @organization.finance_payouts : Finance::Payout
      @payout = scope.includes(:organization, :payout_account).find(params[:id])
    end

    def payout_scope_sample
      Finance::Payout.new(organization: @organization)
    end

    def ledger_scope_sample
      Finance::LedgerEntry.new(organization: @organization)
    end

    def payout_params
      params.require(:payout).permit(:currency, :amount_minor)
    end

    def payout_currency
      params[:currency].to_s.strip.upcase.presence
    end

    def payout_adapter
      Finance::PayoutProviders::Registry.fetch(params[:provider].presence || @payout.provider)
    rescue KeyError
      render_error(
        I18n.t("finance.errors.payout_provider_unavailable"),
        code: "payout_provider_unavailable", status: :unprocessable_entity
      )
      nil
    end

    def treasury_approval
      return nil unless params[:treasury_approval_id].present?

      Core::AuditLog.find(params[:treasury_approval_id])
    end

    def apply_report_ordering(records, default_order)
      return apply_ordering(records.reorder(nil)) if params[:order_by].present?

      records.order(default_order)
    end

    def allowed_order_columns
      return %w[id amount_minor currency type available_at created_at] if action_name == "ledger_entries"

      %w[id amount_minor currency status requested_at paid_at created_at]
    end
  end
end
