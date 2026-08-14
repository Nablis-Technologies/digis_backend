# frozen_string_literal: true

module Orders
  # Read-only refund status boundary. It scopes records through the policy
  # before loading the payment/order graph, keeping buyer status useful while
  # excluding provider and recovery internals from the serializer profile.
  class RefundsController < Orders::ApplicationController
    include Core::Pagination

    def index
      @clazz = Orders::Refund
      authorize Orders::Refund.new, :index?
      refunds = policy_scope(Orders::Refund)
        .includes(payment: :order)
        .order(created_at: :desc)
      render_success(data: refunds, serializer_options: { serializer: Orders::RefundSerializer })
    end

    def show
      @refund = Orders::Refund.includes(payment: { order: :event }).find(params[:id])
      authorize @refund, :show?
      render_success(data: @refund, serializer_options: { serializer: Orders::RefundSerializer })
    end
  end
end
