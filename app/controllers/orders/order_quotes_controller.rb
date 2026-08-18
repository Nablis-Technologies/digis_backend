# frozen_string_literal: true

module Orders
  # Buyer-facing quote preview. It returns only displayable totals and an
  # encrypted token; the later order command receives the exact server-owned
  # Commercial and FX evidence through that token.
  class OrderQuotesController < Orders::ApplicationController
    def create
      event = Events::Event.find(params.require(:event_id))
      authorize Orders::Order.new(event:, buyer_user: current_user), :quote?

      promotion, promotion_code = promotion_context(event)
      return render_invalid_promotion unless promotion_code_valid?(promotion_code, params[:promotion_code])

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

    def promotion_context(event)
      return [ nil, nil ] if params[:promotion_code].blank?

      digest = Catalog::PromotionCode.code_digest_for(
        event_id: event.id,
        code: params[:promotion_code]
      )
      code = Catalog::PromotionCode.includes(:promotion).find_by(code_digest: digest)
      [ code&.promotion, code ]
    end

    def promotion_code_valid?(promotion_code, raw_code)
      raw_code.blank? || promotion_code&.promotion&.event_id == params[:event_id]
    end

    def render_invalid_promotion
      render_error(
        :"catalog.promotion_quote.errors.invalid_code",
        status: :unprocessable_entity,
        code: "invalid_promotion_code"
      )
    end
  end
end
