# frozen_string_literal: true

require "test_helper"

module Commercial
  module Entitlements
    class ConsumeTest < ActiveSupport::TestCase
      include Commercial::EntitlementTestHelpers

      setup do
        @organization = organizations_organizations(:two)
        @program, @assignment = create_first_event_program(organization: @organization)
        @event = create_published_event(organization: @organization, published_at: 1.hour.ago)
        @key = "accepted-order-#{SecureRandom.hex(4)}"
      end

      teardown do
        delete_first_event_program!(@program, @assignment)
        Events::Event.where(id: @event.id).delete_all
      end

      test "consumes the reserved entitlement for the first accepted paid order" do
        result = Commercial::Entitlements::Consume.call(event: @event, idempotency_key: @key)

        assert_predicate result, :success?, result.error&.message
        entitlement = result.value.reload
        assert_equal "consumed", entitlement.status
        assert_nil entitlement.reserved_event_id
        assert_nil entitlement.reserved_at
        assert entitlement.consumed_at
        assert Core::AuditLog.exists?(action: "commercial.program_entitlement.consumed",
                                       auditable_type: entitlement.class.name, auditable_id: entitlement.id)
      end

      test "replaying the accepted order is idempotent and a different order conflicts" do
        subject = -> { Commercial::Entitlements::Consume.call(event: @event, idempotency_key: @key) }

        assert_audit_idempotent(
          subject,
          action: "commercial.program_entitlement.consumed",
          auditable_type: "Commercial::ProgramEntitlement",
          auditable_id: -> {
            Commercial::ProgramEntitlement.where(program_id: @program.id).pick(:id) ||
              "00000000-0000-0000-0000-000000000000"
          }
        )

        conflict = Commercial::Entitlements::Consume.call(event: @event, idempotency_key: "different-order")

        assert_predicate conflict, :failure?
        assert_equal "idempotency_conflict", conflict.error.code
        assert_equal "consumed", Commercial::ProgramEntitlement.find_by!(program: @program).status
      end

      test "a different event cannot consume an already consumed entitlement" do
        first = Commercial::Entitlements::Consume.call(event: @event, idempotency_key: "accepted-order")
        assert_predicate first, :success?, first.error&.message

        other_event = create_published_event(organization: @organization, published_at: 30.minutes.ago)
        result = Commercial::Entitlements::Consume.call(event: other_event, idempotency_key: "other-order")

        assert_predicate result, :failure?
        assert_equal "entitlement_unavailable", result.error.code
        assert_equal "consumed", first.value.reload.status
      ensure
        Commercial::ProgramEntitlement.where(program_id: @program.id).delete_all
        Events::Event.where(id: other_event&.id).delete_all
      end

      test "the later event cannot consume while an earlier published event owns the entitlement" do
        earlier = create_published_event(organization: @organization, published_at: 2.hours.ago)
        later = create_published_event(organization: @organization, published_at: 90.minutes.ago)

        result = Commercial::Entitlements::Consume.call(event: later, idempotency_key: "later-order")

        assert_predicate result, :failure?
        assert_equal "entitlement_unavailable", result.error.code
        assert_equal earlier.id, Commercial::ProgramEntitlement.find_by!(program: @program).reserved_event_id
      ensure
        Commercial::ProgramEntitlement.where(program_id: @program.id).delete_all
        Events::Event.where(id: [ earlier&.id, later&.id ]).delete_all
      end
    end

    class ConsumeConcurrencyTest < ActiveSupport::TestCase
      self.use_transactional_tests = false

      include Commercial::EntitlementTestHelpers

      setup do
        @organization = organizations_organizations(:two)
        @program, @assignment = create_first_event_program(organization: @organization)
        @event = create_published_event(organization: @organization, published_at: 1.hour.ago)
      end

      teardown do
        delete_first_event_program!(@program, @assignment)
        Events::Event.where(id: @event.id).delete_all
      end

      test "concurrent accepted orders cannot consume the entitlement twice" do
        ready = Queue.new
        start = Queue.new
        workers = 2.times.map do |index|
          Thread.new do
            Commercial::ApplicationRecord.connection_pool.with_connection do
              ready << true
              start.pop
              Commercial::Entitlements::Consume.call(
                event: Events::Event.find(@event.id),
                idempotency_key: "concurrent-order-#{index}"
              )
            end
          end
        end

        2.times { ready.pop }
        2.times { start << true }
        results = workers.map(&:value)

        assert_equal 1, results.count(&:success?)
        assert_equal 1, results.count { |result| result.failure? && result.error.code == "idempotency_conflict" }
        assert_equal 1, Commercial::ProgramEntitlement.where(program: @program, status: "consumed").count
      end
    end
  end
end
