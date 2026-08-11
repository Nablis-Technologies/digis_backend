# frozen_string_literal: true

module Ticketing
  # Immutable, one-registration allowance approved by an event manager or
  # platform administrator. It changes only the purchase-limit count.
  class PurchaseLimitOverride < Ticketing::ApplicationRecord
    self.table_name = "ticketing_purchase_limit_overrides"

    REASON_CODES = %w[
      accessibility accommodation community_partner service_recovery sponsor_guest staff_guest
      organizer_exception
    ].freeze

    belongs_to :registration, class_name: "Ticketing::Registration"
    belongs_to :ticket_type, class_name: "Ticketing::TicketType"
    belongs_to :user, class_name: "Core::User"
    belongs_to :scope_event_date, class_name: "Events::EventDate", optional: true
    belongs_to :approved_by, class_name: "Core::User"

    validates :additional_packages, numericality: { only_integer: true, greater_than: 0 }
    validates :reason_code, presence: true, inclusion: { in: REASON_CODES }
    validates :idempotency_key, presence: true, uniqueness: true
    validate :snapshot_matches_registration
    validate :immutable_payload
    before_destroy :prevent_destroy

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id registration_id ticket_type_id user_id scope_event_date_id additional_packages approved_by_id
        reason_code idempotency_key created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[registration ticket_type user scope_event_date approved_by]
    end

    private

    def snapshot_matches_registration
      return if registration.blank?

      errors.add(:ticket_type, :invalid) unless ticket_type_id == registration.ticket_type_id
      errors.add(:user, :invalid) unless user_id == registration.user_id
      errors.add(:scope_event_date, :invalid) unless scope_event_date_id == registration.selected_event_date_id
    end

    def immutable_payload
      return unless persisted?
      return if changes.keys.empty?

      changes.keys.each { |field| errors.add(field, :immutable) }
    end

    def prevent_destroy
      errors.add(:base, :immutable)
      throw :abort
    end
  end
end
