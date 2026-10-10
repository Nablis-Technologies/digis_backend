# frozen_string_literal: true

require "test_helper"

class EventStaffAssignmentModelTest < ActiveSupport::TestCase
    def setup
      @org_one = organizations_organizations(:one)
      @event_one = events_events(:draft_concert)
      @super_admin = core_users(:super_admin)
      @attendee = core_users(:attendee)
    end

    test "inheritance_column is disabled (no STI)" do
      assert Events::EventStaffAssignment.inheritance_column.blank?
    end

    test "invalid role is rejected" do
      assignment = Events::EventStaffAssignment.new(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "wizard",
        status: "active"
      )
      refute assignment.valid?
      assert assignment.errors[:role].present?
    end

    test "invalid status is rejected" do
      assignment = Events::EventStaffAssignment.new(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "staff",
        status: "pending"
      )
      refute assignment.valid?
      assert assignment.errors[:status].present?
    end

    test "duplicate user + event + role is rejected" do
      Events::EventStaffAssignment.create!(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "staff",
        status: "active"
      )
      duplicate = Events::EventStaffAssignment.new(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "staff",
        status: "active"
      )
      refute duplicate.valid?
      assert duplicate.errors[:user_id].present?
      assert_includes(
        duplicate.errors[:user_id],
        I18n.t("events.staff_assignment.errors.duplicate_assignment")
      )
    end

    test "same user with different role is allowed" do
      Events::EventStaffAssignment.create!(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "staff",
        status: "active"
      )
      other = Events::EventStaffAssignment.new(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "scanner",
        status: "active"
      )
      assert other.valid?
    end

    test "one active general role is allowed while a scanner assignment remains independent" do
      Events::EventStaffAssignment.create!(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "staff",
        status: "active"
      )
      manager = Events::EventStaffAssignment.new(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "manager",
        status: "active"
      )
      scanner = Events::EventStaffAssignment.new(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "scanner",
        status: "active"
      )

      refute manager.valid?
      assert manager.errors[:role].present?
      assert_predicate scanner, :valid?
    end

    test "database rejects a concurrent active general role that bypasses validations" do
      Events::EventStaffAssignment.create!(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "staff",
        status: "active"
      )

      assert_raises(ActiveRecord::RecordNotUnique) do
        Events::EventStaffAssignment.insert_all!([ {
          id: SecureRandom.uuid,
          event_id: @event_one.id,
          user_id: @attendee.id,
          organization_id: @org_one.id,
          role: "manager",
          status: "active",
          created_at: Time.current,
          updated_at: Time.current
        } ])
      end
    end

    test "active? is true only for active status" do
      assignment = Events::EventStaffAssignment.new(status: "active")
      assert assignment.active?

      %w[suspended revoked expired].each do |status|
        assignment.status = status
        refute assignment.active?, "expected active? to be false for #{status}"
      end
    end
end
