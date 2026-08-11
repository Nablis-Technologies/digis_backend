# frozen_string_literal: true

module Ticketing
  # A named event-wide or ticket-type registration form. The form selects which
  # version applies; versions, rather than the form itself, contain the mutable
  # draft schema and immutable published evidence.
  class RegistrationForm < Ticketing::ApplicationRecord
    self.table_name = "ticketing_registration_forms"

    belongs_to :event, class_name: "Events::Event"
    belongs_to :ticket_type, class_name: "Ticketing::TicketType", optional: true

    has_many :versions,
             class_name: "Ticketing::RegistrationFormVersion",
             dependent: :restrict_with_exception

    validates :name, presence: true
    validates :active, inclusion: { in: [ true, false ] }
    validate :ticket_type_belongs_to_event
    validate :name_unique_within_scope
    validate :scope_immutable_after_publication

    before_validation :normalize_name

    scope :active, -> { where(active: true) }
    scope :event_wide, -> { where(ticket_type_id: nil) }
    scope :for_ticket_type, ->(ticket_type) { where(ticket_type_id: ticket_type.id) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id ticket_type_id name active created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event ticket_type versions]
    end

    private

    def normalize_name
      self.name = name.to_s.strip.gsub(/\s+/, " ").presence
    end

    def ticket_type_belongs_to_event
      return if ticket_type.blank? || event.blank?

      event_product = ticket_type.event_product
      return if event_product&.event_id == event_id
      return if event_product&.event == event

      errors.add(:ticket_type, :invalid)
    end

    def name_unique_within_scope
      return if event_id.blank? || name.blank?

      relation = self.class.where(event_id: event_id, ticket_type_id: ticket_type_id)
                           .where("lower(name) = lower(?)", name)
      relation = relation.where.not(id: id) if persisted?
      return unless relation.exists?

      errors.add(:name, :taken)
    end

    def scope_immutable_after_publication
      return unless persisted? && (will_save_change_to_event_id? || will_save_change_to_ticket_type_id?)
      return unless RegistrationFormVersion.where(registration_form_id: id).where.not(status: "draft").exists?

      errors.add(:event_id, :immutable) if will_save_change_to_event_id?
      errors.add(:ticket_type_id, :immutable) if will_save_change_to_ticket_type_id?
    end
  end
end
