# frozen_string_literal: true

module Catalog
  # A temporary hold on inventory capacity. Transitions through a state
  # machine: held → committed/released/expired. Tracks admissions_per_unit
  # so venue capacity calculations can convert packages to people count.
  class InventoryReservation < Catalog::ApplicationRecord
    self.table_name = "catalog_inventory_reservations"

    STATUSES = %w[held processing committed released expired].freeze
    ACTIVE_STATUSES = %w[held processing].freeze
    TERMINAL_STATUSES = %w[committed released expired].freeze

    belongs_to :product_inventory, class_name: "Catalog::ProductInventory"

    validates :product_inventory, presence: true
    validates :reservation_group_id, presence: true
    validates :product_inventory_id, uniqueness: { scope: :reservation_group_id, message: I18n.t("catalog.inventory_reservation.errors.duplicate_reservation") }
    validates :quantity, numericality: { only_integer: true, greater_than: 0 }
    validates :admissions_per_unit, numericality: { only_integer: true, greater_than_or_equal_to: 1 }
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
        id product_inventory_id registration_id order_item_id
        reservation_group_id quantity admissions_per_unit status
        expires_at committed_at released_at request_fingerprint
        created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[product_inventory]
    end

    private

    def nonterminal?
      !terminal?
    end

    def owner_mutual_exclusion
      if registration_id.present? && order_item_id.present?
        errors.add(:base, I18n.t("catalog.inventory_reservation.errors.owner_mutual_exclusion"))
      end
    end
  end
end
