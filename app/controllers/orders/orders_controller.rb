# frozen_string_literal: true

module Orders
  # Authenticated checkout command surface. Controllers only authorize,
  # unwrap the buyer-bound quote token, and hand the mutation to one command.
  class OrdersController < Orders::ApplicationController
    before_action :ensure_idempotency_key_present, only: %i[create restart]

    def create
      event = Events::Event.find(params.require(:event_id))
      authorize Orders::Order.new(event:, buyer_user: current_user), :create?

      result = Orders::QuoteToken.decode(
        token: order_params.fetch(:quote_token), event:, buyer: current_user
      )
      return render_service_result(result) if result.failure?

      result = Orders::CreateCheckout.call(
        quote: result.value,
        event:,
        buyer: current_user,
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: Orders::OrderSerializer }
      )
    end

    def restart
      old_order = Orders::Order.includes(:event).find(params[:id])
      authorize old_order, :restart?
      result = Orders::QuoteToken.decode(
        token: order_params.fetch(:quote_token), event: old_order.event, buyer: current_user
      )
      return render_service_result(result) if result.failure?

      result = Orders::RestartCheckout.call(
        old_order:,
        buyer: current_user,
        quote: result.value,
        idempotency_key:
      )
      render_service_result(
        result,
        success_status: :created,
        serializer_options: { serializer: Orders::OrderSerializer }
      )
    end

    private

    def order_params
      params.require(:order).permit(:quote_token)
    end
  end
end
