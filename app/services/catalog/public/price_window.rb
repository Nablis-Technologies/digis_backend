# frozen_string_literal: true

module Catalog
  module Public
    # Keeps public price-window evaluation identical across event and product
    # projections while leaving final pricing to the authoritative quote.
    class PriceWindow
      def self.active?(price, at: Time.current)
        price.active_from <= at && (price.active_to.blank? || price.active_to > at)
      end
    end
  end
end
