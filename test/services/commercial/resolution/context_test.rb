# frozen_string_literal: true

require "test_helper"

module Commercial
  module Resolution
    class ContextTest < ActiveSupport::TestCase
      test "rejects unknown keys instead of accepting an unbounded pricing payload" do
        error = assert_raises(ArgumentError) do
          Context.new(organization_id: "org-1", untrusted_basis_minor: 100)
        end

        assert_includes error.message, I18n.t("commercial.resolution.errors.unknown_context_keys")
      end

      test "accepts only integer trusted monetary inputs" do
        assert_raises(ArgumentError) { Context.new(eligible_order_subtotal_minor: 10.5) }
        assert_raises(ArgumentError) { Context.new(eligible_order_subtotal_minor: -1) }
      end

      test "normalizes and freezes the server-owned context" do
        quoted_at = Time.utc(2026, 8, 11, 10, 11, 12, 123_456)
        context = Context.new(
          organization_id: "org-1",
          currency: "etb",
          quoted_at: quoted_at,
          eligible_order_subtotal_minor: 10_001,
          organizer_payer_selections: { platform_commission: "buyer" }
        )

        assert_predicate context, :frozen?
        assert_equal "ETB", context.currency
        assert_equal quoted_at, context.quoted_at
        assert_equal 10_001, context.basis_value("eligible_order_subtotal")
        assert_predicate context.organizer_payer_selections, :frozen?
        assert_predicate context.to_h, :frozen?
      end

      test "does not expose arbitrary basis names" do
        context = Context.new(eligible_order_subtotal_minor: 100)

        assert_raises(ArgumentError) { context.basis_value("internal_margin") }
      end

      test "rejects payer selections for unsupported component types" do
        assert_raises(ArgumentError) do
          Context.new(organizer_payer_selections: { future_component: "buyer" })
        end
      end
    end
  end
end
