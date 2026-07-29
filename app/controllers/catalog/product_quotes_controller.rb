# frozen_string_literal: true

module Catalog
  class ProductQuotesController < Catalog::ApplicationController
    def create
      product = Catalog::EventProduct.find(params[:product_id])
      authorize product, :create?, policy_class: Catalog::ProductQuotePolicy

      at = quote_time
      return render_error(:"catalog.product_quote.errors.invalid_at", status: :unprocessable_entity) if at.nil?

      result = Catalog::Pricing::Quote.call(
        product: product,
        charge_currency: params[:charge_currency],
        at: at
      )

      if result.success?
        render_success(data: quote_payload(result.value))
      else
        render_error(result.error.message, status: :unprocessable_entity)
      end
    end

    private

    def quote_time
      return Time.current if params[:at].blank?

      Time.iso8601(params[:at].to_s)
    rescue ArgumentError
      nil
    end

    def quote_payload(quote)
      Catalog::ProductQuoteSerializer.new(quote).attributes.symbolize_keys
    end
  end
end
