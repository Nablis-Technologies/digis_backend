# frozen_string_literal: true

module Catalog
  class VenueCapacityReservation < Catalog::ApplicationRecord
    self.table_name = "catalog_venue_capacity_reservations"

    STATUSES = %w[held processing committed released expired].freeze
    ACTIVE_STATUSES = %w[held processing].freeze
    TERMINAL_STATUSES = %w[committed released expired].freeze

    belongs_to :event_date, class_name: "Events::EventDate",
               inverse_of: :venue_capacity_reservations
    belongs_to :event_product, class_name: "Catalog::EventProduct",
               inverse_of: :venue_capacity_reservations

    validates :reservation_group_id, uniqueness: { scope: :event_date_id }
    validates :quantity_people, numericality: { only_integer: true, greater_than: 0 }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :expires_at, presence: true, if: :nonterminal?
    validates :request_fingerprint, presence: true,
                                    format: { with: /\A[0-9a-f]{64}\z/ }
    validate :owner_mutual_exclusion

    scope :active, -> { where(status: ACTIVE_STATUSES) }
    scope :held, -> { where(status: "held") }
    scope :expired, -> { active.where("expires_at < ?", Time.current) }
    scope :by_group, ->(group_id) { where(reservation_group_id: group_id) }

    def held?
      status == "held"
    end

    def processing?
      status == "processing"
    end

    def committed?
      status == "committed"
    end

    def released?
      status == "released"
    end

    def expired?
      status == "expired"
    end

    def active?
      ACTIVE_STATUSES.include?(status)
    end

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id reservation_group_id event_date_id event_product_id
        registration_id order_item_id quantity_people status expires_at
        committed_at released_at request_fingerprint created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event_date event_product]
    end

    private

    def nonterminal?
      !terminal?
    end

    def owner_mutual_exclusion
      return unless registration_id.present? && order_item_id.present?

      errors.add(:base, I18n.t("catalog.inventory_reservation.errors.owner_mutual_exclusion"))
    end
  end
end
