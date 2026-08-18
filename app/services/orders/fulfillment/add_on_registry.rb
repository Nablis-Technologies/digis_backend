# frozen_string_literal: true

module Orders
  module Fulfillment
    # Resolves only the explicit noncredential add-on handlers. Database type
    # values are treated as data and are never constantized into Ruby classes.
    class AddOnRegistry
      HANDLERS = {
        "merchandise" => Merchandise,
        "food" => Food,
        "donation" => Donation,
        "digital_addon" => DigitalAddOn
      }.freeze

      def self.fetch(type)
        HANDLERS[type.to_s]
      end
    end
  end
end
