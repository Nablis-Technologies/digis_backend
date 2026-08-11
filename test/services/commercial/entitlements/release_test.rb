# frozen_string_literal: true

require "test_helper"

module Commercial
  module Entitlements
    class ReleaseTest < ActiveSupport::TestCase
      include Commercial::EntitlementTestHelpers

      setup do
        @organization = organizations_organizations(:two)
        @program, @assignment = create_first_event_program(organization: @organization)
        @event = create_published_event(organization: @organization, published_at: 1.hour.ago)
        result = Commercial::Entitlements::ReconcileFirstEvent.call(event: @event)
        assert_predicate result, :success?, result.error&.message
      end

      teardown do
        delete_first_event_program!(@program, @assignment)
        Events::Event.where(id: @event.id).delete_all
      end

      test "releases an unused reservation only after the event closes" do
        open_result = Commercial::Entitlements::Release.call(event: @event, reason: "event_cancelled", idempotency_key: "release-open")
        assert_predicate open_result, :failure?
        assert_equal "event_not_closed", open_result.error.code

        @event.update!(status: "cancelled")
        result = Commercial::Entitlements::Release.call(event: @event, reason: "event_cancelled", idempotency_key: "release-closed")

        assert_predicate result, :success?, result.error&.message
        entitlement = result.value.reload
        assert_equal "released", entitlement.status
        assert entitlement.released_at
        assert_nil entitlement.reserved_event_id
        assert_nil entitlement.reserved_at
      end

      test "release is idempotent and allows the next qualifying event to reserve the benefit" do
        @event.update!(status: "cancelled")
        subject = -> { Commercial::Entitlements::Release.call(event: @event, reason: "event_cancelled", idempotency_key: "release-replay") }

        assert_audit_idempotent(
          subject,
          action: "commercial.program_entitlement.released",
          auditable_type: "Commercial::ProgramEntitlement",
          auditable_id: -> { Commercial::ProgramEntitlement.find_by!(program: @program).id }
        )

        next_event = create_published_event(organization: @organization, published_at: 30.minutes.ago)
        result = Commercial::Entitlements::ReconcileFirstEvent.call(event: next_event)

        assert_predicate result, :success?, result.error&.message
        assert_equal next_event.id, result.value.reload.reserved_event_id
      ensure
        Commercial::ProgramEntitlement.where(program_id: @program.id).delete_all
        Events::Event.where(id: next_event&.id).delete_all
      end

      test "does not restore a consumed entitlement after cancellation" do
        consumed = Commercial::Entitlements::Consume.call(event: @event, idempotency_key: "accepted-order")
        assert_predicate consumed, :success?, consumed.error&.message
        @event.update!(status: "cancelled")

        result = Commercial::Entitlements::Release.call(event: @event, reason: "event_cancelled", idempotency_key: "release-consumed")

        assert_predicate result, :success?, result.error&.message
        assert_equal "consumed", result.value.reload.status
        assert_nil result.value.released_at
      end

      test "releases a completed event after its final date ends" do
        event_date = @event.event_dates.create!(
          starts_at: 2.hours.ago,
          ends_at: 1.hour.ago,
          status: "completed"
        )

        result = Commercial::Entitlements::Release.call(event: @event, reason: "event_ended", idempotency_key: "release-ended")

        assert_predicate result, :success?, result.error&.message
        assert_equal "released", result.value.reload.status
        assert event_date.persisted?
      end
    end
  end
end
