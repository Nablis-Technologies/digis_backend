# frozen_string_literal: true

require "test_helper"

module Ticketing
  module AccessCodes
    class ConsumeTest < ActiveSupport::TestCase
      setup do
        @event = events_events(:ready_listing)
        @ticket_type = ticket_product(audience: "access_code").ticket_type
        @raw = "VIP-CODE"
        @code = Ticketing::AccessCode.create!(
          ticket_type: @ticket_type,
          code_digest: Ticketing::AccessCode.code_digest_for(
            event_id: @ticket_type.event_product.event_id, code: @raw
          ),
          max_uses: 5,
          max_quantity_per_use: 2
        )
      end

      test "valid code deducts quantity and returns the code" do
        result = Ticketing::AccessCodes::Consume.new(
          ticket_type: @ticket_type, raw_code: @raw, quantity: 2
        ).call
        assert result.success?
        assert_equal 2, result.value.used_count
      end

      test "invalid code fails" do
        result = Ticketing::AccessCodes::Consume.new(
          ticket_type: @ticket_type, raw_code: "nope"
        ).call
        assert result.failure?
        assert_equal 0, @code.reload.used_count
      end

      test "quantity above per-use limit fails" do
        result = Ticketing::AccessCodes::Consume.new(
          ticket_type: @ticket_type, raw_code: @raw, quantity: 3
        ).call
        assert result.failure?
        assert_equal 0, @code.reload.used_count
      end

      test "exhausted code fails without deduction" do
        @code.update!(max_uses: 1, used_count: 1)
        result = Ticketing::AccessCodes::Consume.new(
          ticket_type: @ticket_type, raw_code: @raw
        ).call
        assert result.failure?
        assert_equal 1, @code.reload.used_count
      end

      test "exceeding remaining uses fails" do
        @code.update!(max_uses: 3, used_count: 2)
        result = Ticketing::AccessCodes::Consume.new(
          ticket_type: @ticket_type, raw_code: @raw, quantity: 2
        ).call
        assert result.failure?
        assert_equal 2, @code.reload.used_count
      end

      private

      def ticket_product(audience:, **ticket_attrs)
        Catalog::Products::CreateDraft.call(
          event: @event,
          actor: core_users(:super_admin),
          product_attributes: { name: "VIP", type: "ticket" },
          ticket_type_attributes: {
            audience: audience, approval_mode: "automatic", date_selection: "fixed",
            admissions_per_unit: 1
          }.merge(ticket_attrs),
          inventory_configuration: { mode: "unlimited" }
        ).value
      end
    end
  end
end
