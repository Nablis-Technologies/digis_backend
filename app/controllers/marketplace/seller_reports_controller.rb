# frozen_string_literal: true

module Marketplace
  # Seller read models for immutable history and current balance. No mutable
  # balance counter is introduced; both endpoints derive from ledger/payout
  # facts under the seller policy scope.
  class SellerReportsController < Marketplace::ApplicationController
    include Core::Pagination

    def balance
      authorize SellerLedgerEntry.new(seller_user: current_user), :index?
      result = SellerBalanceReport.call(seller: current_user, currency: params[:currency])
      render_service_result(result)
    end

    def history
      @clazz = SellerLedgerEntry
      authorize SellerLedgerEntry.new(seller_user: current_user), :index?
      entries = policy_scope(@clazz).includes(:event).order(created_at: :desc)
      entries = apply_ordering(entries.reorder(nil)) if params[:order_by].present?
      total_count = entries.count if paginated_request?
      entries = paginated_request? ? apply_pagination(entries) : entries.limit(default_per_page)
      render_success(
        data: entries,
        serializer_options: { serializer: SellerLedgerEntrySerializer },
        pagination: paginated_request? ? pagination_metadata(total_count) : nil
      )
    end

    private

    def allowed_order_columns
      %w[id amount_minor currency type available_at created_at]
    end
  end
end
