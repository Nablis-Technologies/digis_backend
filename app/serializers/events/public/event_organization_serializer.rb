# frozen_string_literal: true

module Events
  module Public
    # Public collaboration projection without organization contacts or
    # membership data.
    class EventOrganizationSerializer < ActiveModel::Serializer
      attributes :id, :type, :role, :status, :organization

      def organization
        Events::Public::OrganizationSummarySerializer.new(object.organization).attributes
      end
    end
  end
end
