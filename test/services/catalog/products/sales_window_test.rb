# frozen_string_literal: true

require "test_helper"

module Catalog
  module Products
    class SalesWindowTest < ActiveSupport::TestCase
      test "sales start is inclusive and sales end is exclusive" do
        at = Time.utc(2026, 9, 29, 12)
        product = Catalog::EventProduct.new(sales_start_at: at, sales_end_at: at)

        assert defined?(SalesWindow), "expected one Catalog product sales-window owner"
        assert_equal :sales_ended, SalesWindow.error_key(product, at:)
        refute SalesWindow.open?(product, at:)
      end
    end
  end
end
