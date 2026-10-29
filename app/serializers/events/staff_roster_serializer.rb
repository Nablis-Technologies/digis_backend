# frozen_string_literal: true

module Events
  class StaffRosterSerializer
    def self.call(roster)
      {
        assignments: page(roster.assignments, EventStaffAssignmentSerializer),
        invitations: page(roster.invitations, StaffInvitationSerializer)
      }
    end

    def self.page(value, serializer)
      {
        data: value.records.map { |record| ActiveModelSerializers::SerializableResource.new(record, serializer:).as_json },
        pagination: value.pagination
      }
    end
    private_class_method :page
  end
end
