# frozen_string_literal: true

require "test_helper"

module Finance
  class EventCompletionsControllerTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers
    include Finance::PayoutTestHelpers

    setup do
      setup_payout_context(status: "published")
      Organizations::Membership.create!(
        user: core_users(:core_admin), organization: @organization,
        role: "owner", status: "active"
      )
    end

    test "delegates event completion to the authoritative command" do
      Finance::CompleteEvent.expects(:call).with(
        event: @event, actor: core_users(:core_admin), idempotency_key: "complete-event-api"
      ).returns(Core::BaseService::Result.success(@event))

      post "/events/#{@event.id}/complete",
           headers: owner_headers.merge("Idempotency-Key" => "complete-event-api"), as: :json

      assert_response :success
      data = response.parsed_body.fetch("data")
      assert_equal @event.id, data.fetch("id")
      assert_not data.key?("organization")
      assert_equal "Event completed successfully", response.parsed_body.fetch("message")
    end

    test "requires an idempotency key" do
      post "/events/#{@event.id}/complete", headers: owner_headers, as: :json

      assert_response :bad_request
      assert_equal "missing_idempotency_key", response.parsed_body.fetch("code")
    end

    test "rejects an attendee from completing an event" do
      post "/events/#{@event.id}/complete",
           headers: user_headers.merge("Idempotency-Key" => "attendee-completion"), as: :json

      assert_response :forbidden
    end

    test "renders the command business error" do
      error = Core::BusinessError.new(
        I18n.t("finance.errors.event_dates_incomplete"),
        code: "event_dates_incomplete", status: :unprocessable_entity
      )
      Finance::CompleteEvent.expects(:call).returns(Core::BaseService::Result.failure(error))

      post "/events/#{@event.id}/complete",
           headers: owner_headers.merge("Idempotency-Key" => "incomplete-event"), as: :json

      assert_response :unprocessable_entity
      assert_equal "event_dates_incomplete", response.parsed_body.fetch("code")
    end
  end
end
