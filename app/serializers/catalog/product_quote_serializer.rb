# frozen_string_literal: true

class Catalog::ProductQuoteSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer

  attributes :product_id, :charge_currency, :amount_minor, :source_type,
             :from_currency, :exchange_rate_id, :exchange_rate_value, :at

  def read_attribute_for_serialization(attr)
    object.public_send(attr)
  end
end
