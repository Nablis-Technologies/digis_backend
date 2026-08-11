# frozen_string_literal: true

require "test_helper"

module Commercial
  class ProgramEntitlementTest < ActiveSupport::TestCase
    include Commercial::EntitlementTestHelpers

    setup do
      @organization = organizations_organizations(:two)
      @program, @assignment = create_first_event_program(organization: @organization)
    end

    teardown do
      delete_first_event_program!(@program, @assignment)
    end

    test "defines the program entitlement model" do
      assert defined?(Commercial::ProgramEntitlement), "ProgramEntitlement must be defined"
    end

    test "requires an organization, program, allowlisted status, and lock version" do
      entitlement = Commercial::ProgramEntitlement.new(
        organization: @organization,
        program: @program,
        status: "unknown",
        lock_version: -1
      )

      assert_not entitlement.valid?
      assert entitlement.errors.key?(:status)
      assert entitlement.errors.key?(:lock_version)

      missing_owner = Commercial::ProgramEntitlement.new(status: "available", lock_version: 0)
      assert_not missing_owner.valid?
      assert missing_owner.errors.key?(:organization)
      assert missing_owner.errors.key?(:program)
    end

    test "enforces state-coupled timestamps and reservation event" do
      event = create_published_event(organization: @organization, published_at: 1.hour.ago)
      invalid_reserved = Commercial::ProgramEntitlement.new(
        organization: @organization,
        program: @program,
        status: "reserved",
        reserved_at: Time.current
      )
      invalid_consumed = Commercial::ProgramEntitlement.new(
        organization: @organization,
        program: @program,
        status: "consumed"
      )
      valid_consumed = Commercial::ProgramEntitlement.new(
        organization: @organization,
        program: @program,
        status: "consumed",
        consumed_at: Time.current,
        lock_version: 0
      )
      valid_reserved = Commercial::ProgramEntitlement.new(
        organization: @organization,
        program: @program,
        reserved_event: event,
        status: "reserved",
        reserved_at: Time.current,
        lock_version: 0
      )

      assert_not invalid_reserved.valid?
      assert_not invalid_consumed.valid?
      assert_predicate valid_reserved, :valid?
      assert_predicate valid_consumed, :valid?
    ensure
      Events::Event.where(id: event&.id).delete_all
    end

    test "database enforces the entitlement state machine" do
      invalid = Commercial::ProgramEntitlement.new(
        organization: @organization,
        program: @program,
        status: "reserved",
        reserved_at: Time.current,
        lock_version: 0
      )

      assert_raises(ActiveRecord::StatementInvalid) { invalid.save!(validate: false) }
    end

    test "couples terminal timestamps and only allows one entitlement per program and organization" do
      entitlement = Commercial::ProgramEntitlement.create!(
        organization: @organization,
        program: @program,
        status: "released",
        released_at: Time.current,
        lock_version: 0
      )

      duplicate = Commercial::ProgramEntitlement.new(
        organization: @organization,
        program: @program,
        status: "available",
        lock_version: 0
      )

      assert_predicate entitlement, :valid?
      assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
    end

    test "requires an expiry timestamp only for expired entitlements" do
      expired = Commercial::ProgramEntitlement.new(
        organization: @organization,
        program: @program,
        status: "expired",
        lock_version: 0
      )
      valid_expired = expired.dup
      valid_expired.expires_at = Time.current

      assert_not expired.valid?
      assert_predicate valid_expired, :valid?
    end

    test "exposes safe query contracts" do
      assert_equal "Commercial::Program", Commercial::ProgramEntitlement.reflect_on_association(:program).class_name
      assert_equal "Organizations::Organization", Commercial::ProgramEntitlement.reflect_on_association(:organization).class_name
      assert_includes Commercial::ProgramEntitlement.ransackable_attributes, "status"
      assert_includes Commercial::ProgramEntitlement.ransackable_associations, "reserved_event"
    end
  end
end
