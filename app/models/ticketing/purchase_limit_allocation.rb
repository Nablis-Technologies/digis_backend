# frozen_string_literal: true

module Ticketing
  # One package unit counted against a verified user's ticket-type limit. The
  # row remains as released history so resale cannot reset the seller's count.
  class PurchaseLimitAllocation < Ticketing::ApplicationRecord
    self.table_name = "ticketing_purchase_limit_allocations"

    STATUSES = %w[reserved committed released].freeze
    RELEASE_REASONS = %w[expired checkout_expired buyer_requested cancelled refunded void resale_replaced].freeze

    belongs_to :ticket_type, class_name: "Ticketing::TicketType"
    belongs_to :user, class_name: "Core::User"
    belongs_to :scope_event_date, class_name: "Events::EventDate", optional: true
    belongs_to :registration, class_name: "Ticketing::Registration"

    validates :unit_number, numericality: { only_integer: true, greater_than: 0 }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :expires_at, presence: true, if: :reserved?
    validates :committed_at, presence: true, if: :committed?
    validates :released_at, :release_reason, presence: true, if: :released?
    validates :release_reason, inclusion: { in: RELEASE_REASONS }, if: :released?
    validates :idempotency_key, presence: true, uniqueness: true
    validate :scope_matches_registration
    validate :state_fields_match
    validate :immutable_identity

    scope :countable, -> { where(status: %w[reserved committed]) }
    scope :expired_reservations, -> { where(status: "reserved").where("expires_at <= ?", Time.current) }

    def reserved? = status == "reserved"

    def committed? = status == "committed"

    def released? = status == "released"

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id ticket_type_id user_id scope_event_date_id registration_id unit_number ticket_id status
        expires_at committed_at released_at release_reason idempotency_key created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[ticket_type user scope_event_date registration]
    end

    private

    def scope_matches_registration
      return if registration.blank? || ticket_type.blank?
      return if ticket_type.date_selection == "choose_one" && scope_event_date_id == registration.selected_event_date_id
      return if ticket_type.date_selection == "fixed" && scope_event_date_id.blank?

      errors.add(:scope_event_date, :invalid)
    end

    def state_fields_match
      if reserved? && (committed_at.present? || released_at.present? || release_reason.present?)
        errors.add(:base, :invalid)
      elsif committed? && (expires_at.present? || released_at.present? || release_reason.present?)
        errors.add(:base, :invalid)
      elsif released? && (expires_at.present? || committed_at.present? || release_reason.blank?)
        errors.add(:base, :invalid)
      end
    end

    def immutable_identity
      return unless persisted?

      immutable_fields = %w[ticket_type_id user_id scope_event_date_id registration_id unit_number ticket_id]
      changed = immutable_fields.select { |field| will_save_change_to_attribute?(field) }
      changed.each { |field| errors.add(field, :immutable) } if changed.any?
    end
  end
end
