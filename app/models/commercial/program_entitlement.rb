# frozen_string_literal: true

module Commercial
  # Holds one limited-use program benefit for an organization.
  #
  # The database check constraint is the final state-machine boundary; these
  # validations keep invalid rows from reaching it during normal command/model
  # use. Event provenance is intentionally represented by audit/outbox metadata
  # after a reservation is consumed or released, so terminal rows cannot look
  # like they still reserve an event.
  class ProgramEntitlement < Commercial::ApplicationRecord
    self.table_name = "commercial_program_entitlements"

    STATUSES = %w[available reserved consumed released expired].freeze

    belongs_to :program, class_name: "Commercial::Program", inverse_of: :entitlements
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :reserved_event, class_name: "Events::Event", optional: true

    validates :program, presence: true
    validates :organization, presence: true
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :lock_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :state_metadata_matches_status

    scope :available, -> { where(status: "available") }
    scope :reserved, -> { where(status: "reserved") }
    scope :consumed, -> { where(status: "consumed") }
    scope :released, -> { where(status: "released") }
    scope :expired, -> { where(status: "expired") }
    scope :for_organization, ->(organization_id) { where(organization_id:) }
    scope :for_program, ->(program_id) { where(program_id:) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id program_id organization_id status reserved_event_id reserved_at consumed_at
        released_at expires_at lock_version created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[program organization reserved_event]
    end

    private

    def state_metadata_matches_status
      return unless status.in?(STATUSES)

      expected = state_metadata
      return if expected.all? { |attribute, present| public_send(attribute).present? == present }

      errors.add(:base, I18n.t("commercial.entitlements.errors.state_metadata"))
    end

    def state_metadata
      case status
      when "available"
        { reserved_event: false, reserved_at: false, consumed_at: false, released_at: false }
      when "reserved"
        { reserved_event: true, reserved_at: true, consumed_at: false, released_at: false }
      when "consumed"
        { reserved_event: false, reserved_at: false, consumed_at: true, released_at: false }
      when "released"
        { reserved_event: false, reserved_at: false, consumed_at: false, released_at: true }
      when "expired"
        { reserved_event: false, reserved_at: false, consumed_at: false, released_at: false,
          expires_at: true }
      else
        {}
      end
    end
  end
end
