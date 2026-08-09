# frozen_string_literal: true

require "test_helper"

module Ticketing
  class ConsentReminderJobTest < ActiveJob::TestCase
    include Ticketing::ConsentTestHelpers

    setup { setup_consent_context }

    test "records one bounded payload-free outbox signal per due requirement" do
      requirement = travel_to(2.days.ago) do
        _document, = create_consent_document(scope: "buyer", required: true)
        build_consent_requirements(accept_required_buyer: false).value.first
      end

      assert_equal 1, Ticketing::ConsentReminderJob.perform_now
      assert_equal "pending", requirement.reload.status
      event = Core::OutboxEvent.find_by!(event_type: "ticketing.registration_consent.reminder_due")
      assert_equal requirement.id, event.payload.fetch("requirement_id")
      assert_equal [ "requirement_id" ], event.payload.keys
      assert_equal 1, Ticketing::ConsentReminderJob.perform_now
      assert_equal 1, Core::OutboxEvent.where(event_type: "ticketing.registration_consent.reminder_due").count
    end

    test "dispatches a reminder with only the requirement id" do
      requirement = travel_to(2.days.ago) do
        _document, = create_consent_document(scope: "buyer", required: true)
        build_consent_requirements(accept_required_buyer: false).value.first
      end
      received_details = nil
      original_sender = Rails.application.config.x.consent_reminder_sender
      Rails.application.config.x.consent_reminder_sender = ->(**details) { received_details = details }

      Ticketing::ConsentReminderJob.perform_now
      event = Core::OutboxEvent.find_by!(event_type: "ticketing.registration_consent.reminder_due")
      result = Core::Outbox::Dispatch.call(event_id: event.id)

      assert_predicate result, :success?
      assert_equal event.id, result.value.id
      assert_not_nil event.reload.published_at
      assert_equal({ requirement_id: requirement.id }, received_details)
    ensure
      Rails.application.config.x.consent_reminder_sender = original_sender
    end

    test "production recurring schedule invokes the consent reminder job" do
      schedule = YAML.load_file(Rails.root.join("config/recurring.yml"))

      assert_equal "Ticketing::ConsentReminderJob", schedule.dig("production", "remind_pending_consents", "class")
    end
  end
end
