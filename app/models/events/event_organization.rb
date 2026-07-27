# frozen_string_literal: true

module Events
  class EventOrganization < Events::ApplicationRecord
    self.table_name = "events_event_organizations"
    self.inheritance_column = nil

    include Core::AuditableModel

    attribute :status, :string, default: "active"

    TYPES = %w[co_organizer venue_partner promoter sponsor].freeze
    STATUSES = %w[pending active revoked].freeze

    belongs_to :event, class_name: "Events::Event", inverse_of: :event_organizations
    belongs_to :organization, class_name: "Organizations::Organization"

    validates :type, presence: true, inclusion: { in: TYPES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :role, presence: true, exclusion: { in: [ "primary_owner" ] }
    validates :organization_id, uniqueness: { scope: :event_id,
                                              message: :duplicate_collaborator }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id type event_id organization_id role status created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event organization]
    end
  end
end
