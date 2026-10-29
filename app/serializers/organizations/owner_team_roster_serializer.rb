# frozen_string_literal: true

module Organizations
  class OwnerTeamRosterSerializer
    def self.call(roster)
      {
        memberships: page(roster.memberships, MembershipSerializer),
        invitations: page(roster.invitations, MembershipInvitationSerializer)
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
