# frozen_string_literal: true

require "test_helper"

module Commercial
  class VolumeUsageTest < ActiveSupport::TestCase
    include Commercial::VolumeTestHelpers

    setup do
      setup_volume_context
      @order = create_volume_order
    end

    test "accepts immutable accepted-order usage for an event counter" do
      usage = build_usage

      assert_predicate usage, :valid?, usage.errors.full_messages.to_sentence
      assert_equal @order.event_id, usage.event_id
    end

    test "requires gross currency and rejects currency for unit usage" do
      missing = build_usage(metric_type: "accepted_gross", currency: nil)
      assert_not missing.valid?
      assert_includes missing.errors.attribute_names, :currency

      unit_currency = build_usage(currency: "ETB")
      assert_not unit_currency.valid?
      assert_includes unit_currency.errors.attribute_names, :currency

      other_currency = build_usage(metric_type: "accepted_gross", currency: "USD")
      assert_not other_currency.valid?
      assert_includes other_currency.errors.attribute_names, :currency
    end

    test "keeps accepted usage immutable and retained" do
      usage = Commercial::VolumeUsage.create!(usage_attributes)
      usage.value = 20

      assert_not usage.save
      assert_includes usage.errors.attribute_names, :value
      assert_raises(ActiveRecord::ReadOnlyRecord) { usage.destroy! }
      assert Commercial::VolumeUsage.exists?(usage.id)
    end

    test "does not record the same accepted order/component/window twice" do
      Commercial::VolumeUsage.create!(usage_attributes)
      duplicate = Commercial::VolumeUsage.new(usage_attributes)

      assert_not duplicate.valid?
      assert_includes duplicate.errors.attribute_names, :order_id
      assert_raises(ActiveRecord::RecordNotUnique) do
        Commercial::VolumeUsage.insert_all!([ insert_usage_attributes.merge(id: SecureRandom.uuid) ])
      end
    end

    test "database rejects usage for an order that never reached accepted payment" do
      draft = create_volume_order(status: "draft")

      assert_raises(ActiveRecord::StatementInvalid) do
        Commercial::VolumeUsage.insert_all!([
          insert_usage_attributes.merge(id: SecureRandom.uuid, order_id: draft.id, event_id: draft.event_id)
        ])
      end
    end

    test "exposes the usage associations and searchable evidence" do
      assert_includes Commercial::VolumeUsage.ransackable_attributes, "order_id"
      assert_includes Commercial::VolumeUsage.ransackable_attributes, "value"
      assert_includes Commercial::VolumeUsage.ransackable_associations, "order"
      assert_includes Commercial::VolumeUsage.ransackable_associations, "fee_component"
    end

    private

    def build_usage(attributes = {})
      Commercial::VolumeUsage.new(usage_attributes.merge(attributes))
    end

    def usage_attributes
      {
        fee_component: @component,
        organization: @organization,
        event: @event,
        order: @order,
        metric_type: "accepted_paid_units",
        window_type: "event",
        window_start_at: @quoted_at - 1.day,
        window_end_at: @quoted_at + 1.day,
        value: 2,
        accepted_at: @quoted_at
      }
    end

    def insert_usage_attributes
      usage_attributes.except(:fee_component, :organization, :event, :order).merge(
        fee_component_id: @component.id,
        organization_id: @organization.id,
        event_id: @event.id,
        order_id: @order.id
      )
    end
  end
end
