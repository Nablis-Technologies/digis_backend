# frozen_string_literal: true

require "test_helper"

class Catalog::ProductQuoteStreamingTest < ActiveSupport::TestCase
  include StreamingTestHelpers

  test "discloses the sharing limitation for a paid soft-gated YouTube product" do
    build_streaming_ticket(now: Time.current, access_protection: "soft_gated")
    quote = Catalog::PriceQuote.new(
      product_id: @stream_product.id,
      charge_currency: "ETB",
      amount_minor: 1_000,
      source_type: "base",
      from_currency: "ETB",
      exchange_rate_id: nil,
      exchange_rate_value: nil,
      at: Time.current
    )

    data = Catalog::ProductQuoteSerializer.new(quote, product: @stream_product).attributes

    assert_equal "soft_gated", data[:stream_access_protection]
    assert_equal "soft_gated_youtube_link_sharing", data[:stream_access_notice_code]
  end
end
