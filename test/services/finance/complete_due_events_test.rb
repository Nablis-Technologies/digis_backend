# frozen_string_literal: true

require "test_helper"

module Finance
  class CompleteDueEventsTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @now = Time.utc(2026, 8, 27, 12, 0, 0)
      @organization = Organizations::Organization.create!(
        name: "Due Event Organization #{SecureRandom.hex(4)}",
        slug: "due-event-organization-#{SecureRandom.hex(4)}",
        organizer_type: "company",
        category: "music"
      )
    end

    test "completes a published event whose scheduled date has ended" do
      event = create_event(title: "Ended event")
      date = create_date(event, starts_at: @now - 2.hours, ends_at: @now - 1.hour)

      assert_enqueued_with(job: Finance::MatureEventFundsJob, args: [ event.id ]) do
        result = Finance::CompleteDueEvents.call(at: @now)

        assert_predicate result, :success?, result.error&.message
        assert_equal [ event.id ], result.value
      end

      assert_equal "completed", event.reload.status
      assert_equal "completed", date.reload.status
    end

    test "leaves a published event pending when a future date remains" do
      event = create_event(title: "Mixed dates")
      ended = create_date(event, starts_at: @now - 2.hours, ends_at: @now - 1.hour)
      future = create_date(event, starts_at: @now + 1.hour, ends_at: @now + 2.hours)

      result = Finance::CompleteDueEvents.call(at: @now)

      assert_predicate result, :success?, result.error&.message
      assert_empty result.value
      assert_equal "published", event.reload.status
      assert_equal "completed", ended.reload.status
      assert_equal "scheduled", future.reload.status
    end

    test "does not select draft cancelled completed or future-only events" do
      create_event(title: "Draft", status: "draft").tap do |event|
        create_date(event, starts_at: @now - 2.hours, ends_at: @now - 1.hour)
      end
      create_event(title: "Cancelled", status: "cancelled").tap do |event|
        create_date(event, starts_at: @now - 2.hours, ends_at: @now - 1.hour)
      end
      create_event(title: "Completed", status: "completed", completed_at: @now - 1.hour).tap do |event|
        create_date(event, starts_at: @now - 2.hours, ends_at: @now - 1.hour, status: "completed")
      end
      future = create_event(title: "Future")
      create_date(future, starts_at: @now + 1.hour, ends_at: @now + 2.hours)

      result = Finance::CompleteDueEvents.call(at: @now)

      assert_predicate result, :success?, result.error&.message
      assert_empty result.value
    end

    test "continues past benign completion races" do
      first = create_event(title: "Race one")
      second = create_event(title: "Race two")
      third = create_event(title: "Race three")
      fourth = create_event(title: "Race four")
      [ first, second, third, fourth ].each do |event|
        create_date(event, starts_at: @now - 2.hours, ends_at: @now - 1.hour)
      end
      service = Finance::CompleteDueEvents.new(at: @now)
      service.stubs(:candidate_events).returns([ first, second, third, fourth ])

      Finance::CompleteEvent.expects(:call).times(4).returns(
        failure_result("event_already_completed"),
        failure_result("event_not_completable"),
        failure_result("event_dates_incomplete"),
        Core::BaseService::Result.success(fourth)
      )

      result = service.call

      assert_equal [ fourth.id ], result.value
    end

    test "processes the rest of the batch before raising persistent failures" do
      first = create_event(title: "Poisoned event")
      second = create_event(title: "Following event")
      [ first, second ].each do |event|
        create_date(event, starts_at: @now - 2.hours, ends_at: @now - 1.hour)
      end
      service = Finance::CompleteDueEvents.new(at: @now)
      service.stubs(:candidate_events).returns([ first, second ])
      failure = failure_result("event_completion_invalid")

      Finance::CompleteEvent.expects(:call).times(2).returns(
        failure, Core::BaseService::Result.success(second)
      )

      error = assert_raises(Finance::CompleteDueEvents::SweepFailure) { service.call }

      assert_equal [ second.id ], error.completed_ids
      assert_equal [ { event_id: first.id, code: "event_completion_invalid" } ], error.failures
    end

    private

    def create_event(title:, status: "published", completed_at: nil)
      Events::Event.create!(
        organization: @organization,
        created_by: core_users(:super_admin),
        title: "#{title} #{SecureRandom.hex(4)}",
        slug: "#{title.parameterize}-#{SecureRandom.hex(4)}",
        visibility: "public",
        timezone: "Africa/Addis_Ababa",
        currency: "ETB",
        status:,
        published_at: status.in?(%w[published cancelled]) ? @now - 1.day : nil,
        completed_at:
      )
    end

    def create_date(event, starts_at:, ends_at:, status: "scheduled")
      event.event_dates.create!(starts_at:, ends_at:, status:)
    end

    def failure_result(code)
      Core::BaseService::Result.failure(
        Core::BusinessError.new(
          I18n.t("finance.errors.#{code}"), code:, status: :unprocessable_entity
        )
      )
    end
  end
end
