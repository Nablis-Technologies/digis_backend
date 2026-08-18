# frozen_string_literal: true

require "test_helper"

module Commercial
  class VolumeCounterTest < ActiveSupport::TestCase
    include Commercial::VolumeTestHelpers

    setup do
      setup_volume_context
    end

    test "accepts an event-scoped accepted-units counter" do
      counter = Commercial::VolumeCounter.new(
        fee_component: @component,
        organization: @organization,
        event: @event,
        metric_type: "accepted_paid_units",
        window_type: "event",
        window_start_at: @quoted_at - 1.day,
        window_end_at: @quoted_at + 1.day,
        value: 12,
        lock_version: 0
      )

      assert_predicate counter, :valid?, counter.errors.full_messages.to_sentence
    end

    test "requires currency only for gross counters and rejects it for unit counters" do
      units = build_counter
      assert_predicate units, :valid?, units.errors.full_messages.to_sentence

      gross = build_counter(metric_type: "accepted_gross", currency: "ETB")
      assert_predicate gross, :valid?, gross.errors.full_messages.to_sentence

      missing_currency = build_counter(metric_type: "accepted_gross", currency: nil)
      assert_not missing_currency.valid?
      assert_includes missing_currency.errors.attribute_names, :currency

      unit_currency = build_counter(currency: "ETB")
      assert_not unit_currency.valid?
      assert_includes unit_currency.errors.attribute_names, :currency
    end

    test "rejects invalid windows, metrics, and negative cached values" do
      invalid = build_counter(
        metric_type: "unknown",
        window_type: "unknown",
        window_start_at: @quoted_at,
        window_end_at: @quoted_at - 1.second,
        value: -1,
        lock_version: -1
      )

      assert_not invalid.valid?
      assert_includes invalid.errors.attribute_names, :metric_type
      assert_includes invalid.errors.attribute_names, :window_type
      assert_includes invalid.errors.attribute_names, :window_end_at
      assert_includes invalid.errors.attribute_names, :value
      assert_includes invalid.errors.attribute_names, :lock_version
    end

    test "enforces one counter for its complete commercial dimension" do
      first = Commercial::VolumeCounter.create!(counter_attributes)
      duplicate = Commercial::VolumeCounter.new(counter_attributes)

      assert_not duplicate.valid?
      assert_includes duplicate.errors.attribute_names, :fee_component_id
      assert_raises(ActiveRecord::RecordNotUnique) do
        Commercial::VolumeCounter.insert_all!([ insert_counter_attributes.merge(id: SecureRandom.uuid) ])
      end
      assert_predicate first, :persisted?
    end

    test "exposes only the searchable counter contract" do
      assert_includes Commercial::VolumeCounter.ransackable_attributes, "value"
      assert_includes Commercial::VolumeCounter.ransackable_attributes, "window_start_at"
      assert_includes Commercial::VolumeCounter.ransackable_associations, "fee_component"
      assert_includes Commercial::VolumeCounter.ransackable_associations, "organization"
      assert_includes Commercial::VolumeCounter.ransackable_associations, "event"
    end

    private

    def build_counter(attributes = {})
      Commercial::VolumeCounter.new(counter_attributes.merge(attributes))
    end

    def counter_attributes
      {
        fee_component: @component,
        organization: @organization,
        event: @event,
        metric_type: "accepted_paid_units",
        window_type: "event",
        window_start_at: @quoted_at - 1.day,
        window_end_at: @quoted_at + 1.day,
        value: 0,
        lock_version: 0
      }
    end

    def insert_counter_attributes
      counter_attributes.except(:fee_component, :organization, :event).merge(
        fee_component_id: @component.id,
        organization_id: @organization.id,
        event_id: @event.id
      )
    end
  end
end
