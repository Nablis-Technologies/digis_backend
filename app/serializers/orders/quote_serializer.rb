# frozen_string_literal: true

module Orders
  # Presents buyer-visible quote evidence without serializing Commercial
  # definitions, provider routing, promotion digests, or organizer totals.
  class QuoteSerializer < ActiveModel::Serializer
    attributes :quote_token, :charge_currency, :sales_channel, :quoted_at,
               :expires_at, :subtotal_minor, :discount_minor, :subsidy_total,
               :buyer_fee_total, :total_minor, :items

    def quote_token
      instance_options.fetch(:quote_token)
    end

    def items
      object.items.map do |item|
        {
          product_id: item.product_id,
          name: item.name,
          type: item.type,
          quantity: item.quantity,
          unit_amount_minor: item.price_quote.amount_minor,
          subtotal_minor: item.subtotal_minor,
          discount_minor: item.promotion_discount_minor,
          total_minor: item.subtotal_minor - item.promotion_discount_minor
        }
      end
    end

    def read_attribute_for_serialization(attribute)
      return public_send(attribute) if respond_to?(attribute, true)

      object.public_send(attribute)
    end
  end
end
