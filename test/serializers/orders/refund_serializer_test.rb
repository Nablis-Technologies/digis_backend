# frozen_string_literal: true

require "test_helper"

module Orders
  class RefundSerializerTest < ActiveSupport::TestCase
    include Orders::RefundApiTestHelpers

    test "serializer declares operational fields so policy visibility can remove them" do
      refund = create_api_refund
      attributes = Orders::RefundSerializer.new(refund).attributes.keys.map(&:to_sym)

      assert_includes attributes, :amount_minor
      assert_includes attributes, :currency
      assert_includes attributes, :status
      assert_includes attributes, :provider_reference
      assert_includes attributes, :provider_fee_minor
      assert_includes attributes, :pending_reason
    end
  end
end
