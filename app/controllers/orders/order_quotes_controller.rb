# frozen_string_literal: true

module Orders
  # Buyer-facing quote preview. It returns only displayable totals and an
  # encrypted token; the later order command receives the exact server-owned
  # Commercial and FX evidence through that token.
  class OrderQuotesController < Orders::ApplicationController
    def create
      event = Events::Event.find(params.require(:event_id))
      authorize Orders::Order.new(event:, buyer_user: current_user), :quote?

      promotion_result = Orders::PromotionContext.call(event:, raw_code: params[:promotion_code])
      return render_service_result(promotion_result) if promotion_result.failure?
      promotion = promotion_result.value.promotion

      result = Orders::BuildQuote.call(
        event:,
        buyer: current_user,
        items: item_requests,
        charge_currency: params.require(:charge_currency),
        provider: params[:provider],
        payment_method: params[:payment_method],
        promotion:,
        promotion_code: params[:promotion_code]
      )
      return render_service_result(result) if result.failure?

      token = Orders::QuoteToken.issue(quote: result.value, event:, buyer: current_user)
      data = Orders::QuoteSerializer.new(result.value, quote_token: token).attributes.symbolize_keys
      render_success(data:)
    end

    private

    def item_requests
      Array(params[:items]).map do |item|
        attributes = item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h : item
        attributes = attributes.to_h.symbolize_keys
        attributes.slice(
          :event_product_id, :quantity, :registration_id, :event_date_ids, :venue_event_date_ids
        ).merge(product_id: attributes[:event_product_id])
      end
    end
  end
end
