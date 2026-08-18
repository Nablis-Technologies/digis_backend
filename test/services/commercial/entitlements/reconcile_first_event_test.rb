# frozen_string_literal: true

require "test_helper"

module Commercial
  module Entitlements
    class ReconcileFirstEventTest < ActiveSupport::TestCase
      include Commercial::EntitlementTestHelpers

      setup do
        @organization = organizations_organizations(:two)
        @program, @assignment = create_first_event_program(organization: @organization)
      end

      teardown do
        delete_first_event_program!(@program, @assignment)
      end

      test "creates and reserves the automatic entitlement for the earliest published event" do
        published_at = 2.hours.ago
        event = create_published_event(organization: @organization, published_at:)

        result = Commercial::Entitlements::ReconcileFirstEvent.call(event:)

        assert_predicate result, :success?, result.error&.message
        entitlement = result.value
        assert_equal "reserved", entitlement.status
        assert_equal event.id, entitlement.reserved_event_id
        assert_equal published_at.to_i, entitlement.reserved_event.published_at.to_i
        assert_equal 1, Commercial::ProgramEntitlement.where(program: @program, organization: @organization).count
      end

      test "does not automatically enroll a manual program" do
        @program.update!(enrollment_mode: "manual")
        event = create_published_event(organization: @organization, published_at: 1.hour.ago)

        result = Commercial::Entitlements::ReconcileFirstEvent.call(event:)

        assert_predicate result, :success?, result.error&.message
        assert_nil result.value
        assert_empty Commercial::ProgramEntitlement.where(program: @program, organization: @organization)
      end

      test "a delayed earlier publication displaces a later delivery reservation" do
        later = create_published_event(organization: @organization, published_at: 2.hours.ago)
        earlier = create_published_event(organization: @organization, published_at: 3.hours.ago)

        later_result = Commercial::Entitlements::ReconcileFirstEvent.call(event: later)
        earlier_result = Commercial::Entitlements::ReconcileFirstEvent.call(event: earlier)

        assert_predicate later_result, :success?, later_result.error&.message
        assert_predicate earlier_result, :success?, earlier_result.error&.message
        assert_equal earlier.id, earlier_result.value.reload.reserved_event_id
      end

      test "replaying publication reconciliation is idempotent" do
        event = create_published_event(organization: @organization, published_at: 1.hour.ago)
        subject = -> { Commercial::Entitlements::ReconcileFirstEvent.call(event:) }

        assert_idempotent(subject, counter: -> { Commercial::ProgramEntitlement.where(program: @program).count })
        assert_equal 1, Core::AuditLog.where(
          action: "commercial.program_entitlement.reserved",
          auditable_type: "Commercial::ProgramEntitlement"
        ).count
      end

      test "expires an automatic entitlement whose program window has passed" do
        @program.update!(ends_at: 1.minute.ago)
        event = create_published_event(organization: @organization, published_at: Time.current)

        result = Commercial::Entitlements::ReconcileFirstEvent.call(event:)

        assert_predicate result, :success?, result.error&.message
        assert_nil result.value
        assert_empty Commercial::ProgramEntitlement.where(program: @program, organization: @organization)
      end
    end

    class ReconcileFirstEventConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      include Commercial::EntitlementTestHelpers

      setup do
        @organization = organizations_organizations(:two)
        @program, @assignment = create_first_event_program(organization: @organization)
        @earlier = create_published_event(organization: @organization, published_at: 3.hours.ago)
        @later = create_published_event(organization: @organization, published_at: 2.hours.ago)
      end

      teardown do
        delete_first_event_program!(@program, @assignment)
        Events::Event.where(id: [ @earlier.id, @later.id ]).delete_all
      end

      test "concurrent deliveries leave exactly one reservation for the earliest event" do
        ready = Queue.new
        start = Queue.new
        workers = [ @earlier, @later ].map do |event|
          Thread.new do
            Commercial::ApplicationRecord.connection_pool.with_connection do
              ready << true
              start.pop
              Commercial::Entitlements::ReconcileFirstEvent.call(event: Events::Event.find(event.id))
            end
          end
        end

        2.times { ready.pop }
        2.times { start << true }
        results = workers.map(&:value)

        assert results.all?(&:success?), results.filter_map { |result| result.error&.message }.join(", ")
        entitlement = Commercial::ProgramEntitlement.find_by!(program: @program, organization: @organization)
        assert_equal @earlier.id, entitlement.reserved_event_id
        assert_equal 1, Commercial::ProgramEntitlement.where(program: @program, organization: @organization).count
      end
    end
  end
end
