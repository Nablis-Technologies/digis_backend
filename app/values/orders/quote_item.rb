# frozen_string_literal: true

module Orders
  # Immutable line evidence carried from quote creation into checkout. It keeps
  # only server-owned identifiers and snapshots; checkout reloads the records
  # it must lock without trusting a mutable Active Record object from the quote.
  QuoteItem = Data.define(
    :product_id, :name, :type, :quantity, :registration_id,
    :event_date_ids, :venue_event_date_ids, :admissions_per_unit,
    :price_quote, :base_unit_amount_minor, :commercial_result, :subtotal_minor,
    :promotion_discount_minor
  ) do
    def initialize(**attributes)
      attributes[:event_date_ids] = Array(attributes[:event_date_ids]).map(&:to_s).sort.freeze
      attributes[:venue_event_date_ids] = Array(attributes[:venue_event_date_ids]).map(&:to_s).sort.freeze
      super(**attributes)
    end
  end
end
