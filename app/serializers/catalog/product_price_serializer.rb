# frozen_string_literal: true

class Catalog::ProductPriceSerializer < ActiveModel::Serializer
  include Core::AttributeVisibilitySerializer

  attributes :id, :type, :currency, :amount_minor, :active_from, :active_to,
             :ticket_type_id, :event_product_id
end
