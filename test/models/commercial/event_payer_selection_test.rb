# frozen_string_literal: true

require "test_helper"

module Commercial
  class EventPayerSelectionTest < ActiveSupport::TestCase
    include Commercial::VolumeTestHelpers

    setup do
      setup_volume_context
      @component = create_component(
        @version,
        component_type: "platform_commission",
        charged_to: "organizer",
        funded_by: "organizer",
        organizer_payer_choice: true,
        label: "Selectable commission"
      )
    end

    test "accepts a buyer or organizer selection for one event/component" do
      selection = Commercial::EventPayerSelection.new(selection_attributes)

      assert_predicate selection, :valid?, selection.errors.full_messages.to_sentence
      assert_equal @event.id, selection.event_id
      assert_equal @component.id, selection.fee_component_id
    end

    test "rejects unsupported payer values and malformed request evidence" do
      invalid = Commercial::EventPayerSelection.new(
        selection_attributes.merge(charged_to: "platform", idempotency_key_digest: "a" * 63)
      )

      assert_not invalid.valid?
      assert_includes invalid.errors.attribute_names, :charged_to
      assert_includes invalid.errors.attribute_names, :idempotency_key_digest
    end

    test "enforces one current selection for an event/component" do
      Commercial::EventPayerSelection.create!(selection_attributes)
      duplicate = Commercial::EventPayerSelection.new(selection_attributes)

      assert_not duplicate.valid?
      assert_includes duplicate.errors.attribute_names, :event_id
      assert_raises(ActiveRecord::RecordNotUnique) do
        Commercial::EventPayerSelection.insert_all!([
          insert_selection_attributes.merge(id: SecureRandom.uuid, idempotency_key_digest: "c" * 64)
        ])
      end
    end

    test "exposes only the searchable selection contract" do
      assert_includes Commercial::EventPayerSelection.ransackable_attributes, "charged_to"
      assert_includes Commercial::EventPayerSelection.ransackable_attributes, "selected_at"
      assert_includes Commercial::EventPayerSelection.ransackable_associations, "event"
      assert_includes Commercial::EventPayerSelection.ransackable_associations, "fee_component"
      assert_includes Commercial::EventPayerSelection.ransackable_associations, "selected_by"
    end

    private

    def selection_attributes
      {
        event: @event,
        fee_component: @component,
        charged_to: "buyer",
        selected_by: core_users(:attendee),
        selected_at: @quoted_at,
        idempotency_key_digest: "a" * 64,
        request_fingerprint: "b" * 64
      }
    end

    def insert_selection_attributes
      selection_attributes.except(:event, :fee_component, :selected_by).merge(
        event_id: @event.id,
        fee_component_id: @component.id,
        selected_by_id: core_users(:attendee).id
      )
    end
  end
end
