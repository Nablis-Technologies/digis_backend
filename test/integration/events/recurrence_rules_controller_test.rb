# frozen_string_literal: true

require "test_helper"

module Events
  class RecurrenceRulesIntegrationTest < ActionDispatch::IntegrationTest
    include Core::AuthTestHelpers

    def setup
      @event = events_events(:ready_listing)
    end

    def create_rule
      post "/events/#{@event.id}/recurrence_rule",
           params: { recurrence_rule: {
             rrule: "FREQ=DAILY;COUNT=3",
             timezone: "Africa/Addis_Ababa",
             dtstart_local: "2026-08-01T20:00:00",
             duration_seconds: 3600
           } },
           headers: owner_headers, as: :json
    end

    test "owner can create a recurrence rule (active defaults to true)" do
      assert_difference -> { Events::RecurrenceRule.where(event: @event).count }, 1 do
        create_rule
      end
      assert_response :created
      assert_equal I18n.t("events.recurrence.success.create"), JSON.parse(response.body)["message"]
      assert Events::RecurrenceRule.find_by(event: @event).active?
    end

    test "creating a rule ignores an explicit active flag in the body" do
      post "/events/#{@event.id}/recurrence_rule",
           params: { recurrence_rule: {
             rrule: "FREQ=DAILY;COUNT=3",
             timezone: "Africa/Addis_Ababa",
             dtstart_local: "2026-08-01T20:00:00",
             duration_seconds: 3600,
             active: false
           } },
           headers: owner_headers, as: :json
      assert_response :created
      assert Events::RecurrenceRule.find_by(event: @event).active?
    end

    test "updating a rule ignores an explicit active flag in the body" do
      create_rule
      rule = Events::RecurrenceRule.find_by(event: @event)
      rule.update!(active: false)

      patch "/events/#{@event.id}/recurrence_rule",
            params: { recurrence_rule: { rrule: "FREQ=WEEKLY;COUNT=2", active: true } },
            headers: owner_headers, as: :json
      assert_response :ok
      assert_equal I18n.t("events.recurrence.success.update"), JSON.parse(response.body)["message"]
      assert_not rule.reload.active?
    end

    test "owner can fetch the recurrence rule" do
      create_rule
      get "/events/#{@event.id}/recurrence_rule", headers: owner_headers, as: :json
      assert_response :ok
      assert_equal I18n.t("events.recurrence.success.show"), JSON.parse(response.body)["message"]
    end

    test "owner can delete the recurrence rule" do
      create_rule
      rule = Events::RecurrenceRule.find_by(event: @event)

      delete "/events/#{@event.id}/recurrence_rule", headers: owner_headers, as: :json
      assert_response :ok
      assert_equal I18n.t("events.recurrence.success.destroy"), JSON.parse(response.body)["message"]
      assert_not Events::RecurrenceRule.exists?(rule.id)
    end

    test "owner can activate a deactivated recurrence rule" do
      create_rule
      rule = Events::RecurrenceRule.find_by(event: @event)
      rule.update!(active: false)

      post "/events/#{@event.id}/recurrence_rule/activate", headers: owner_headers, as: :json

      assert_response :ok
      assert_equal I18n.t("events.recurrence.success.activate"), JSON.parse(response.body)["message"]
      assert rule.reload.active?
    end

    test "activating an already-active rule is idempotent" do
      create_rule
      rule = Events::RecurrenceRule.find_by(event: @event)

      post "/events/#{@event.id}/recurrence_rule/activate", headers: owner_headers, as: :json
      assert_response :ok
      assert rule.reload.active?
    end

    test "owner can deactivate a recurrence rule" do
      create_rule
      rule = Events::RecurrenceRule.find_by(event: @event)

      post "/events/#{@event.id}/recurrence_rule/deactivate", headers: owner_headers, as: :json

      assert_response :ok
      assert_equal I18n.t("events.recurrence.success.deactivate"), JSON.parse(response.body)["message"]
      assert_not rule.reload.active?
    end

    test "activating without a rule returns not found" do
      post "/events/#{@event.id}/recurrence_rule/activate", headers: owner_headers, as: :json
      assert_response :not_found
    end

    test "outsider cannot activate a recurrence rule" do
      create_rule
      post "/events/#{@event.id}/recurrence_rule/activate", headers: user_headers, as: :json
      assert_response :forbidden
    end

    test "outsider cannot deactivate a recurrence rule" do
      create_rule
      post "/events/#{@event.id}/recurrence_rule/deactivate", headers: user_headers, as: :json
      assert_response :forbidden
    end
  end
end
