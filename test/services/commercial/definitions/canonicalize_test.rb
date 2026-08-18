# frozen_string_literal: true

require "test_helper"

module Commercial
  module Definitions
    class CanonicalizeTest < ActiveSupport::TestCase
      include Commercial::FeeDefinitionTestHelpers

      test "produces the same digest regardless of component insertion order" do
        schedule = create_schedule
        first = create_version(schedule, version: 1)
        create_component(first, component_type: "buyer_service_fee", label: "Buyer service")
        create_component(first, component_type: "platform_commission")

        second = create_version(schedule, version: 2)
        create_component(second, component_type: "platform_commission")
        create_component(second, component_type: "buyer_service_fee", label: "Buyer service")

        first_result = Commercial::Definitions::Canonicalize.call(version: first)
        second_result = Commercial::Definitions::Canonicalize.call(version: second)

        assert_predicate first_result, :success?
        assert_equal first_result.value.digest, second_result.value.digest
        assert_equal first_result.value.definition, second_result.value.definition
      end

      test "changes the digest for a financially meaningful field" do
        version = create_version(create_schedule)
        component = create_component(version)
        original = Commercial::Definitions::Canonicalize.call(version: version).value.digest

        component.update!(rate_bps: 900)
        changed = Commercial::Definitions::Canonicalize.call(version: version).value.digest

        refute_equal original, changed
      end

      test "returns an allowlisted deeply frozen representation" do
        version = create_version(create_schedule)
        create_component(version)

        result = Commercial::Definitions::Canonicalize.call(version: version)

        assert_deeply_frozen(result.value.definition)
        assert_equal 64, result.value.digest.length
        assert_equal %i[components schedule_type], result.value.definition.keys.sort
        assert_nil result.value.definition[:components].first[:id]
      end

      private

      def assert_deeply_frozen(value)
        assert_predicate value, :frozen?
        values = value.is_a?(Hash) ? value.keys + value.values : value
        values = [ value ] unless value.is_a?(Array) || value.is_a?(Hash)
        values.each { |child| assert_deeply_frozen(child) if child.is_a?(Array) || child.is_a?(Hash) }
        values.each { |child| assert_predicate child, :frozen? if child.is_a?(String) || child.is_a?(Symbol) }
      end
    end
  end
end
