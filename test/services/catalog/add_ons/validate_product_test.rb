# frozen_string_literal: true

require "test_helper"

module Catalog
  module AddOns
    class ValidateProductTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
      end

      test "accepts every noncredential add-on type" do
        %w[merchandise food donation digital_addon].each do |type|
          result = ValidateProduct.call(product: build_product(type:))

          assert_predicate result, :success?, result.error&.message
        end
      end

      test "rejects parking, ticket, and other products until their owning workflow is available" do
        %w[parking ticket other].each do |type|
          result = ValidateProduct.call(product: build_product(type:))

          assert_predicate result, :failure?
          assert_equal "unsupported_add_on_type", result.error.code
        end
      end

      test "accepts a positive custom amount only for custom-price donations" do
        donation = build_product(type: "donation", allow_custom_price: true)
        fixed_donation = build_product(type: "donation")
        merchandise = build_product(type: "merchandise", allow_custom_price: true)

        assert_predicate ValidateProduct.call(product: donation, custom_amount_minor: 250), :success?

        fixed_result = ValidateProduct.call(product: fixed_donation, custom_amount_minor: 250)
        assert_predicate fixed_result, :failure?
        assert_equal "custom_price_not_allowed", fixed_result.error.code

        non_donation_result = ValidateProduct.call(product: merchandise, custom_amount_minor: 250)
        assert_predicate non_donation_result, :failure?
        assert_equal "custom_price_not_allowed", non_donation_result.error.code
      end

      test "rejects zero, negative, and noninteger custom amounts" do
        product = build_product(type: "donation", allow_custom_price: true)

        [ 0, -1, 1.5, "250" ].each do |amount|
          result = ValidateProduct.call(product:, custom_amount_minor: amount)

          assert_predicate result, :failure?
          assert_equal "custom_amount_invalid", result.error.code
        end
      end

      private

      def build_product(type:, allow_custom_price: false)
        attributes = {
          event: @event,
          name: "#{type} #{SecureRandom.hex(4)}",
          type:,
          status: "active",
          inventory_mode: "unlimited",
          allow_custom_price:,
          schedule_change_refund_policy: "full_or_partial",
          min_per_order: 1
        }
        return Catalog::EventProduct.new(attributes) if type == "ticket"

        Catalog::EventProduct.create!(attributes)
      end
    end
  end
end
