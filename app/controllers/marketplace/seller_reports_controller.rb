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
      entries = policy_scope(@clazz).order(created_at: :desc)
      render_success(data: entries, serializer_options: { serializer: SellerLedgerEntrySerializer })
    end
  end
end
