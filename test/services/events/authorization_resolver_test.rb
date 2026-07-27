# frozen_string_literal: true

require "test_helper"

class AuthorizationResolverServiceTest < ActiveSupport::TestCase
    def setup
      @super_admin = core_users(:super_admin)
      @core_admin = core_users(:core_admin)
      @attendee = core_users(:attendee)
      @org_one = organizations_organizations(:one)
      @org_two = organizations_organizations(:two)
      @event_one = events_events(:draft_concert)   # org one (super_admin owner)
      @event_two = events_events(:ready_listing)   # org two (core_admin owner)
    end

    test "access_granted? returns false for nil user or nil event" do
      assert_equal false, Events::AuthorizationResolver.access_granted?(nil, @event_two)
      assert_equal false, Events::AuthorizationResolver.access_granted?(@core_admin, nil)
    end

    test "super admin is granted access to any event" do
      assert Events::AuthorizationResolver.access_granted?(@super_admin, @event_two)
    end

    test "admin is granted access to any event" do
      assert Events::AuthorizationResolver.access_granted?(@core_admin, @event_one)
    end

    test "organization owner is granted access without an explicit assignment" do
      # core_admin is owner of org_two, which owns ready_listing
      assert Events::AuthorizationResolver.access_granted?(@core_admin, @event_two)
    end

    test "outsider with no membership or assignment is denied access" do
      # attendee has no membership in org_one nor assignment on draft_concert
      refute Events::AuthorizationResolver.access_granted?(@attendee, @event_one)
    end

    test "active staff assignment grants access" do
      Events::EventStaffAssignment.create!(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "staff",
        status: "active"
      )
      assert Events::AuthorizationResolver.access_granted?(@attendee, @event_one)
    end

    test "suspended assignment does not grant access" do
      Events::EventStaffAssignment.create!(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "staff",
        status: "suspended"
      )
      refute Events::AuthorizationResolver.access_granted?(@attendee, @event_one)
    end

    test "revoked assignment does not grant access" do
      Events::EventStaffAssignment.create!(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "staff",
        status: "revoked"
      )
      refute Events::AuthorizationResolver.access_granted?(@attendee, @event_one)
    end

    test "expired assignment does not grant access" do
      Events::EventStaffAssignment.create!(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "staff",
        status: "expired"
      )
      refute Events::AuthorizationResolver.access_granted?(@attendee, @event_one)
    end

    test "role_for returns :none for nil user" do
      assert_equal :none, Events::AuthorizationResolver.role_for(nil, @event_two)
    end

    test "role_for returns :none for nil event" do
      assert_equal :none, Events::AuthorizationResolver.role_for(@core_admin, nil)
    end

    test "role_for returns :super_admin for super admin" do
      assert_equal :super_admin, Events::AuthorizationResolver.role_for(@super_admin, @event_two)
    end

    test "role_for returns :admin for admin" do
      assert_equal :admin, Events::AuthorizationResolver.role_for(@core_admin, @event_one)
    end

    test "role_for returns :admin for a platform admin who is also an org owner" do
      assert_equal :admin, Events::AuthorizationResolver.role_for(@core_admin, @event_two)
    end

    test "role_for reflects active assignment type" do
      Events::EventStaffAssignment.create!(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "scanner",
        status: "active"
      )
      assert_equal :scanner, Events::AuthorizationResolver.role_for(@attendee, @event_one)
    end

    test "role_for returns :none for outsider" do
      assert_equal :none, Events::AuthorizationResolver.role_for(@attendee, @event_one)
    end

    test "can_assign? returns false for nil actor or nil event" do
      refute Events::AuthorizationResolver.can_assign?(nil, @event_two, "staff")
      refute Events::AuthorizationResolver.can_assign?(@core_admin, nil, "staff")
    end

    test "owner can assign any target type" do
      assert Events::AuthorizationResolver.can_assign?(@core_admin, @event_two, "manager")
      assert Events::AuthorizationResolver.can_assign?(@core_admin, @event_two, "staff")
    end

    test "super admin can assign any target type" do
      assert Events::AuthorizationResolver.can_assign?(@super_admin, @event_two, "manager")
    end

    test "admin can assign any target type" do
      assert Events::AuthorizationResolver.can_assign?(@core_admin, @event_one, "manager")
    end

    test "manager can assign staff and scanner but not manager" do
      Events::EventStaffAssignment.create!(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "manager",
        status: "active"
      )
      assert Events::AuthorizationResolver.can_assign?(@attendee, @event_one, "staff")
      assert Events::AuthorizationResolver.can_assign?(@attendee, @event_one, "scanner")
      refute Events::AuthorizationResolver.can_assign?(@attendee, @event_one, "manager")
      refute Events::AuthorizationResolver.can_assign?(@attendee, @event_one, "contractor")
    end

    test "plain staff cannot assign anything" do
      Events::EventStaffAssignment.create!(
        event: @event_one,
        user: @attendee,
        organization: @org_one,
        role: "staff",
        status: "active"
      )
      refute Events::AuthorizationResolver.can_assign?(@attendee, @event_one, "staff")
      refute Events::AuthorizationResolver.can_assign?(@attendee, @event_one, "scanner")
    end
end
