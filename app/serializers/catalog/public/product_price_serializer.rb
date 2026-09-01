# frozen_string_literal: true

module Catalog
  module Public
    # Public price option without pricing-rule or internal identity fields.
    class ProductPriceSerializer < ActiveModel::Serializer
      attributes :currency, :amount_minor, :active_from, :active_to
    end
  end
end
