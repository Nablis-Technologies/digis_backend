# frozen_string_literal: true

require "test_helper"

module Commercial
  module EventPayerSelections
    class SetTest < ActiveSupport::TestCase
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
        @actor = core_users(:attendee)
      end

      test "sets and audits an event payer choice" do
        result = Commercial::EventPayerSelections::Set.call(
          event: @event,
          fee_component: @component,
          charged_to: "buyer",
          selected_by: @actor,
          idempotency_key: "payer-choice-1"
        )

        assert_predicate result, :success?, result.error&.message
        selection = result.value
        assert_equal "buyer", selection.charged_to
        assert_equal @actor.id, selection.selected_by_id
        assert Core::AuditLog.exists?(auditable: selection, action: "commercial.event_payer_selection.set")
        assert Core::OutboxEvent.exists?(event_type: "commercial.event_payer_selection.set")
      end

      test "returns the original selection on exact replay and rejects a key conflict" do
        attributes = {
          event: @event, fee_component: @component, charged_to: "buyer",
          selected_by: @actor, idempotency_key: "payer-choice-replay"
        }
        first = Commercial::EventPayerSelections::Set.call(**attributes)
        replay = Commercial::EventPayerSelections::Set.call(**attributes)
        conflict = Commercial::EventPayerSelections::Set.call(**attributes.merge(charged_to: "organizer"))

        assert_predicate first, :success?, first.error&.message
        assert_predicate replay, :success?, replay.error&.message
        assert_equal first.value.id, replay.value.id
        assert_predicate conflict, :failure?
        assert_equal "idempotency_conflict", conflict.error.code
        assert_equal 1, Core::AuditLog.where(
          auditable_type: "Commercial::EventPayerSelection",
          auditable_id: first.value.id,
          action: "commercial.event_payer_selection.set"
        ).count
      end

      test "rejects a selection when the resolved component does not permit payer choice" do
        @component.update!(organizer_payer_choice: false)

        result = Commercial::EventPayerSelections::Set.call(
          event: @event,
          fee_component: @component,
          charged_to: "buyer",
          selected_by: @actor,
          idempotency_key: "payer-choice-forbidden"
        )

        assert_predicate result, :failure?
        assert_equal "payer_selection_forbidden", result.error.code
      end

      test "rejects a product-scoped component from another event" do
        product = create_product(event: events_events(:ready_listing))
        component = create_component(
          @version, event_product: product, charged_to: "organizer", funded_by: "organizer",
          organizer_payer_choice: true
        )

        result = Commercial::EventPayerSelections::Set.call(
          event: @event, fee_component: component, charged_to: "buyer",
          selected_by: @actor, idempotency_key: "payer-choice-wrong-event"
        )

        assert_predicate result, :failure?
        assert_equal "selection_event_mismatch", result.error.code
      end
    end
  end
end
