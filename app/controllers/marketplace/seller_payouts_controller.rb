# frozen_string_literal: true

module Marketplace
  # Seller payout lifecycle API. Payout creation reserves only the caller's
  # currency balance and dispatches asynchronously through the outbox.
  class SellerPayoutsController < Marketplace::ApplicationController
    include Core::Pagination
    include Core::CommandResponse

    before_action :ensure_idempotency_key_present, only: :create
    before_action :load_payout, only: :show

    def index
      payout = SellerPayout.new(seller_user: current_user)
      authorize payout, :index?
      payouts = policy_scope(
        SellerPayout, policy_scope_class: SellerPayoutPolicy::SellerScope
      )
      payouts = params[:order_by].present? ? apply_ordering(payouts) : payouts.order(requested_at: :desc)
      total_count = payouts.count if paginated_request?
      payouts = paginated_request? ? apply_pagination(payouts) : payouts.limit(default_per_page)
      render_success(
        data: payouts,
        serializer_options: { serializer: SellerPayoutSerializer },
        pagination: paginated_request? ? pagination_metadata(total_count) : nil
      )
    end

    def show
      authorize @payout, :show?
      render_success(data: @payout, serializer_options: { serializer: SellerPayoutSerializer })
    end

    def create
      payout = SellerPayout.new(seller_user: current_user)
      authorize payout, :create?
      attributes = payout_params
      result = SellerPayouts::Request.call(
        seller: current_user,
        currency: attributes[:currency],
        amount_minor: attributes[:amount_minor],
        seller_payout_account_id: attributes[:seller_payout_account_id],
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: SellerPayoutSerializer }
      )
    end

    private

    def load_payout
      @payout = policy_scope(
        SellerPayout, policy_scope_class: SellerPayoutPolicy::SellerScope
      ).find(params[:id])
    end

    def payout_params
      params.require(:payout).permit(:currency, :amount_minor, :seller_payout_account_id)
    end

    def allowed_order_columns
      %w[id amount_minor currency status requested_at created_at]
    end
  end
end
