# frozen_string_literal: true

module Catalog
  # Publicly safe organizer report row. It contains only aggregate product and
  # money fields; no order buyer, answer, consent, credential, payout, or note.
  class AddOnSalesRowSerializer < ActiveModel::Serializer
    attributes :product_id, :type, :name, :quantity, :gross_minor, :refunded_minor,
               :net_minor, :currency, :settlement_currency
  end
end
