# frozen_string_literal: true

require "test_helper"

module Commercial
  class EventPayerSelectionsTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include CommercialIntegrationHelpers

    setup do
      @event = events_events(:ready_listing)
      @product = build_event_product(@event)
      schedule = build_commercial_schedule(code: "payer_terms")
      version, = build_commercial_version(schedule)
      @component = version.fee_components.first
      @component.update!(event_product: @product, organizer_payer_choice: true)
    end

    test "an organizer can set and replay an event payer selection" do
      params = { event_payer_selection: { fee_component_id: @component.id, charged_to: "organizer" } }

      assert_difference -> { ::Commercial::EventPayerSelection.count }, 1 do
        post "/commercial/events/#{@event.id}/event_payer_selections", params:,
             headers: owner_headers.merge("Idempotency-Key" => "payer-selection-1"), as: :json
        assert_response :success

        post "/commercial/events/#{@event.id}/event_payer_selections", params:,
             headers: owner_headers.merge("Idempotency-Key" => "payer-selection-1"), as: :json
        assert_response :success
      end
    end

    test "payer selection requires an Idempotency-Key" do
      post "/commercial/events/#{@event.id}/event_payer_selections",
           params: { event_payer_selection: { fee_component_id: @component.id, charged_to: "organizer" } },
           headers: owner_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", JSON.parse(response.body)["code"]
    end
  end
end
