# frozen_string_literal: true

module Ticketing
  # The commercial package boundary for one issued ticket unit. Ownership,
  # acquisition, refund state, and the current credential generation remain on
  # this row; admission credentials are replaceable children.
  class Ticket < Ticketing::ApplicationRecord
    self.table_name = "ticketing_tickets"

    ACQUISITION_TYPES = %w[
      primary_purchase resale_purchase free_registration free_transfer complimentary
    ].freeze
    CREDENTIAL_MODES = %w[group delegated].freeze
    STATUSES = %w[active suspended refunded void].freeze
    PAID_ACQUISITION_TYPES = %w[primary_purchase resale_purchase].freeze
    FREE_ACQUISITION_TYPES = %w[free_registration free_transfer complimentary].freeze

    belongs_to :event, class_name: "Events::Event"
    belongs_to :event_product, class_name: "Catalog::EventProduct"
    belongs_to :registration, class_name: "Ticketing::Registration", optional: true
    belongs_to :order_item, class_name: "Orders::OrderItem", optional: true
    belongs_to :owner_user, class_name: "Core::User"
    belongs_to :current_acquisition_order_item,
               class_name: "Orders::OrderItem",
               optional: true
    belongs_to :current_credential_generation,
               class_name: "Ticketing::CredentialGeneration",
               optional: true

    has_many :admission_slots,
             class_name: "Ticketing::AdmissionSlot",
             dependent: :restrict_with_exception
    has_many :credential_generations,
             class_name: "Ticketing::CredentialGeneration",
             dependent: :restrict_with_exception
    has_many :credentials,
             through: :credential_generations,
             source: :credentials
    has_many :attendee_index_entries,
             class_name: "Ticketing::AttendeeIndexEntry",
             dependent: :restrict_with_exception
    has_one :revocation,
            class_name: "Ticketing::Revocation",
            dependent: :restrict_with_exception

    validates :unit_number, :admissions_per_unit_snapshot, :credential_version,
              numericality: { only_integer: true, greater_than: 0 }
    validates :completed_resale_count, :current_acquisition_product_value_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :current_acquisition_type, presence: true, inclusion: { in: ACQUISITION_TYPES }
    validates :credential_mode, presence: true, inclusion: { in: CREDENTIAL_MODES }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :current_acquisition_currency, format: { with: /\A[A-Z]{3}\z/ }

    validate :fulfillment_source_present
    validate :acquisition_fields_match
    validate :event_scope_matches

    scope :active, -> { where(status: "active") }

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_id event_product_id registration_id order_item_id unit_number
        admissions_per_unit_snapshot owner_user_id current_acquisition_type
        current_acquisition_order_item_id current_acquisition_product_value_minor
        current_acquisition_currency completed_resale_count credential_mode credential_version
        current_credential_generation_id status issued_at lock_version created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event event_product registration order_item owner_user current_credential_generation
         admission_slots credential_generations credentials attendee_index_entries revocation]
    end

    private

    def fulfillment_source_present
      return if registration_id.present? || order_item_id.present?

      errors.add(:base, :invalid)
    end

    def acquisition_fields_match
      return if current_acquisition_type.blank?

      if PAID_ACQUISITION_TYPES.include?(current_acquisition_type)
        errors.add(:current_acquisition_order_item, :blank) if current_acquisition_order_item_id.blank?
      elsif FREE_ACQUISITION_TYPES.include?(current_acquisition_type)
        errors.add(:current_acquisition_order_item, :invalid) if current_acquisition_order_item_id.present?
        errors.add(:current_acquisition_product_value_minor, :invalid) unless current_acquisition_product_value_minor.to_i.zero?
      end
    end

    def event_scope_matches
      product_event_id = if association(:event_product).loaded?
        event_product&.event_id
      else
        Catalog::EventProduct.where(id: event_product_id).pick(:event_id)
      end
      errors.add(:event_product, :invalid) if product_event_id.present? && product_event_id != event_id
      product_type = if association(:event_product).loaded?
        event_product&.type
      else
        Catalog::EventProduct.where(id: event_product_id).pick(:type)
      end
      errors.add(:event_product, :invalid) if product_type.present? && product_type != "ticket"

      registration_event_id = if association(:registration).loaded?
        registration&.event_id
      else
        Ticketing::Registration.where(id: registration_id).pick(:event_id)
      end
      errors.add(:registration, :invalid) if registration_event_id.present? && registration_event_id != event_id

      order_event_id = if association(:order_item).loaded?
        order_item&.order&.event_id
      else
        Orders::OrderItem.joins(:order).where(id: order_item_id).pick("orders_orders.event_id")
      end
      errors.add(:order_item, :invalid) if order_event_id.present? && order_event_id != event_id
    end
  end
end
