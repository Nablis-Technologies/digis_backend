# frozen_string_literal: true

require "test_helper"

module Commercial
  class FeeComponentTest < ActiveSupport::TestCase
    include Commercial::FeeDefinitionTestHelpers

    test "uses semantic Commercial component types" do
      assert_equal %w[
        platform_commission buyer_service_fee processing_cost_recovery
        platform_subsidy resale_platform_fee
      ], Commercial::FeeComponent::COMPONENT_TYPES
    end

    test "requires a basis for percentage, blended, and tiered calculations" do
      version = create_version(create_schedule)

      %w[percentage blended tiered].each do |calculation_type|
        component = build_component(version, calculation_type: calculation_type, basis_type: nil)

        assert_not component.valid?, calculation_type
        assert_includes component.errors[:basis_type], "is required for this calculation"
      end
    end

    test "limits payer, funder, refund, and subsidy combinations" do
      version = create_version(create_schedule)
      invalid_payer = build_component(version, charged_to: "platform")
      invalid_funder = build_component(version, funded_by: "vendor")
      invalid_refund = build_component(version, refund_policy: "credit_only")
      invalid_subsidy = build_component(
        version,
        component_type: "platform_subsidy",
        funded_by: "organizer"
      )

      [ invalid_payer, invalid_funder, invalid_refund, invalid_subsidy ].each do |component|
        assert_not component.valid?
      end

      assert_includes invalid_subsidy.errors[:funded_by], "must be platform for a platform subsidy"
    end

    test "normalizes scope currency and rejects unsupported scope values" do
      version = create_version(create_schedule)
      component = build_component(
        version,
        currency: "usd",
        sale_context: "resale",
        product_type: "parking",
        provider: "chapa",
        payment_method: "telebirr",
        sales_channel: "online"
      )

      assert_predicate component, :valid?
      assert_equal "USD", component.currency

      invalid = build_component(version, sales_channel: "cash")

      assert_not invalid.valid?
      assert_includes invalid.errors[:sales_channel], "is not included in the list"
    end

    test "rejects an offset on non-subsidy components" do
      version = create_version(create_schedule)
      component = build_component(version, offset_component_type: "platform_commission")

      assert_not component.valid?
      assert_includes component.errors[:offset_component_type], "is only allowed for platform subsidies"
    end

    test "rejects nested definition edits after approval" do
      schedule = create_schedule
      version = create_version(schedule)
      component = create_component(version)
      version.update!(
        status: "approved",
        approved_by: core_users(:super_admin),
        approved_at: Time.current,
        effective_from: 1.hour.from_now
      )

      component.rate_bps = 1_000

      assert_not component.valid?
      assert_includes component.errors[:base], I18n.t("commercial.definitions.errors.immutable")
    end

    test "database blocks bulk component edits after approval" do
      schedule = create_schedule
      version = create_version(schedule)
      component = create_component(version)
      version.update!(
        status: "approved",
        approved_by: core_users(:super_admin),
        approved_at: Time.current,
        effective_from: 1.hour.from_now
      )

      assert_raises(ActiveRecord::StatementInvalid) do
        Commercial::FeeComponent.where(id: component.id).update_all(rate_bps: 1_000)
      end
    end
  end
end
