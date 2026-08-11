# frozen_string_literal: true

require "test_helper"

module Commercial
  module Definitions
    class ValidateTest < ActiveSupport::TestCase
      include Commercial::FeeDefinitionTestHelpers

      test "accepts a complete percentage definition and binds its digest" do
        version = create_version(create_schedule)
        create_component(version)
        sync_definition_digest(version)

        result = Commercial::Definitions::Validate.call(version: version)

        assert_predicate result, :success?
        assert_equal version.definition_digest, result.value.digest
      end

      test "rejects invalid calculation shapes with a stable error code" do
        version = create_version(create_schedule)
        component = create_component(
          version,
          calculation_type: "tiered",
          rate_bps: nil,
          basis_type: "accepted_paid_units"
        )
        create_amount(component)

        result = Commercial::Definitions::Validate.call(version: version)

        assert_predicate result, :failure?
        assert_equal "invalid_component_shape", result.error.code
        assert_instance_of Core::BusinessError, result.error
      end

      test "requires fixed currency coverage when currencies are supplied" do
        version = create_version(create_schedule)
        create_component(version, calculation_type: "fixed", rate_bps: nil, basis_type: nil)

        result = Commercial::Definitions::Validate.call(version: version, currencies: %w[ETB USD])

        assert_predicate result, :failure?
        assert_equal "missing_currency_coverage", result.error.code
      end

      test "rejects equal-specificity duplicate scopes" do
        version = create_version(create_schedule)
        create_component(version)
        create_component(version)

        result = Commercial::Definitions::Validate.call(version: version)

        assert_predicate result, :failure?
        assert_equal "ambiguous_component_scope", result.error.code
      end

      test "requires tiers to start at zero and increase by position and threshold" do
        version = create_version(create_schedule)
        component = create_component(
          version,
          calculation_type: "tiered",
          basis_type: "accepted_paid_units",
          rate_bps: nil
        )
        create_tier(component, position: 1, starts_at_value: 10)
        create_tier(component, position: 2, starts_at_value: 10)

        result = Commercial::Definitions::Validate.call(version: version)

        assert_predicate result, :failure?
        assert_equal "tiers_invalid", result.error.code
      end

      test "permits exact product scope only for a custom schedule targeting its event" do
        product = create_product
        default_version = create_version(
          create_schedule(schedule_type: "platform_default", code: "default_schedule")
        )
        create_component(default_version, event_product: product)

        non_custom = Commercial::Definitions::Validate.call(version: default_version, target_event_id: product.event_id)
        assert_equal "exact_product_scope_requires_custom_schedule", non_custom.error.code

        custom_version = create_version(create_schedule, version: 1)
        create_component(custom_version, event_product: product)
        sync_definition_digest(custom_version)

        wrong_event = Commercial::Definitions::Validate.call(
          version: custom_version, target_event_id: events_events(:draft_concert).id
        )
        correct_event = Commercial::Definitions::Validate.call(
          version: custom_version, target_event_id: product.event_id
        )

        assert_equal "exact_product_scope_event_mismatch", wrong_event.error.code
        assert_predicate correct_event, :success?
      end

      test "rejects a stale definition digest" do
        version = create_version(create_schedule)
        create_component(version)

        result = Commercial::Definitions::Validate.call(version: version)

        assert_predicate result, :failure?
        assert_equal "definition_digest_mismatch", result.error.code
      end
    end
  end
end
