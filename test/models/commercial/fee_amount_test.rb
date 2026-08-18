# frozen_string_literal: true

require "test_helper"

module Commercial
  class FeeAmountTest < ActiveSupport::TestCase
    include Commercial::FeeDefinitionTestHelpers

    setup do
      @component = create_component(create_version(create_schedule))
    end

    test "normalizes ISO currency codes" do
      amount = @component.fee_amounts.build(currency: "usd", fixed_amount_minor: 250)

      assert_predicate amount, :valid?
      assert_equal "USD", amount.currency
    end

    test "requires nonnegative amounts and ordered bounds" do
      negative = @component.fee_amounts.build(currency: "ETB", fixed_amount_minor: -1)
      reversed = @component.fee_amounts.build(
        currency: "USD", minimum_minor: 500, maximum_minor: 100
      )

      assert_not negative.valid?
      assert_not reversed.valid?
      assert_includes negative.errors[:fixed_amount_minor], "must be greater than or equal to 0"
      assert_includes reversed.errors[:maximum_minor], "must be greater than or equal to minimum_minor"
    end

    test "enforces one amount per component and currency" do
      @component.fee_amounts.create!(currency: "ETB", fixed_amount_minor: 100)
      duplicate = @component.fee_amounts.build(currency: "etb", fixed_amount_minor: 200)

      assert_not duplicate.valid?
      assert_includes duplicate.errors[:currency], "has already been taken"
    end

    test "rejects edits after the parent version is approved" do
      amount = create_amount(@component)
      @component.fee_schedule_version.update!(
        status: "approved",
        approved_by: core_users(:super_admin),
        approved_at: Time.current,
        effective_from: 1.hour.from_now
      )
      amount.fixed_amount_minor = 999

      assert_not amount.valid?
      assert_includes amount.errors[:base], I18n.t("commercial.definitions.errors.immutable")
    end

    test "database blocks bulk amount edits after approval" do
      amount = create_amount(@component)
      @component.fee_schedule_version.update!(
        status: "approved",
        approved_by: core_users(:super_admin),
        approved_at: Time.current,
        effective_from: 1.hour.from_now
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Commercial::FeeAmount.where(id: amount.id).update_all(fixed_amount_minor: 999)
      end
    end
  end
end
