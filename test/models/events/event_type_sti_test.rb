# frozen_string_literal: true

require "test_helper"

class Events::BusinessTypeStiTest < ActiveSupport::TestCase
  test "EventOrganization does not instantiate STI subclasses from type" do
    org = Events::EventOrganization.create!(
      event: events_events(:draft_concert),
      organization: organizations_organizations(:one),
      type: "co_organizer"
    )
    reloaded = Events::EventOrganization.find(org.id)
    assert_equal "co_organizer", reloaded.type
    assert_instance_of Events::EventOrganization, reloaded
  end

  test "EventStaffAssignment does not instantiate STI subclasses from type" do
    assignment = Events::EventStaffAssignment.create!(
      event: events_events(:draft_concert),
      user: core_users(:super_admin),
      organization: organizations_organizations(:one),
      type: "manager"
    )
    reloaded = Events::EventStaffAssignment.find(assignment.id)
    assert_equal "manager", reloaded.type
    assert_instance_of Events::EventStaffAssignment, reloaded
  end
end
