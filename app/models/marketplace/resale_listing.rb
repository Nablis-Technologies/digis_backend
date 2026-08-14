# frozen_string_literal: true

module Marketplace
  # Seller-owned offer for one already-issued ticket. The listing snapshots
  # the ticket's acquisition economics and the approved Commercial evidence
  # so later policy or fee-definition edits cannot rewrite a live offer.
  class ResaleListing < Marketplace::ApplicationRecord
    self.table_name = "marketplace_resale_listings"

    STATUSES = %w[draft active reserved sold cancelled expired].freeze
    CAP_TYPES = %w[fixed percentage].freeze

    belongs_to :event, class_name: "Events::Event"
    belongs_to :ticket, class_name: "Ticketing::Ticket"
    belongs_to :ticket_type, class_name: "Ticketing::TicketType"
    belongs_to :seller_user, class_name: "Core::User"
    belongs_to :reserved_order, class_name: "Orders::Order", optional: true
    belongs_to :commercial_fee_component, class_name: "Commercial::FeeComponent"
    belongs_to :commercial_fee_schedule_version, class_name: "Commercial::FeeScheduleVersion"

    has_many :resale_sales,
             class_name: "Marketplace::ResaleSale",
             dependent: :restrict_with_exception

    before_validation :normalize_currency

    validates :event, :ticket, :ticket_type, :seller_user, :status, :asking_amount_minor,
              :currency, :seller_acquisition_product_value_minor, :cap_type_snapshot,
              :calculated_cap_minor, :resale_cutoff_at, :commercial_fee_component,
              :commercial_fee_schedule_version, :idempotency_key, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :cap_type_snapshot, inclusion: { in: CAP_TYPES }
    validates :asking_amount_minor, :seller_acquisition_product_value_minor, :calculated_cap_minor,
              numericality: { only_integer: true, greater_than: 0 }
    validates :max_completed_resales_snapshot,
              numericality: { only_integer: true, greater_than: 0 }
    validates :resale_count_before, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :fixed_cap_minor_snapshot, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :percentage_cap_bps_snapshot,
              numericality: { only_integer: true, in: 1..10_000 }, allow_nil: true
    validates :idempotency_key, uniqueness: true

    validate :cap_snapshot_shape
    validate :asking_amount_within_cap
    validate :reservation_shape
    validate :lifecycle_shape
    validate :ticket_scope

    def open?
      status.in?(%w[active reserved])
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id event_id ticket_id ticket_type_id seller_user_id status asking_amount_minor currency
         seller_acquisition_product_value_minor cap_type_snapshot fixed_cap_minor_snapshot
         percentage_cap_bps_snapshot calculated_cap_minor resale_count_before max_completed_resales_snapshot
         resale_cutoff_at commercial_fee_component_id commercial_fee_schedule_version_id reserved_order_id
         reserved_at reservation_expires_at activated_at sold_at closed_at idempotency_key created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event ticket ticket_type seller_user reserved_order resale_sales commercial_fee_component
         commercial_fee_schedule_version]
    end

    private

    def normalize_currency
      self.currency = currency.to_s.strip.upcase.presence
    end

    def cap_snapshot_shape
      if cap_type_snapshot == "fixed"
        errors.add(:fixed_cap_minor_snapshot, :blank) if fixed_cap_minor_snapshot.blank?
        errors.add(:percentage_cap_bps_snapshot, :invalid) if percentage_cap_bps_snapshot.present?
      elsif cap_type_snapshot == "percentage"
        errors.add(:percentage_cap_bps_snapshot, :blank) if percentage_cap_bps_snapshot.blank?
        errors.add(:fixed_cap_minor_snapshot, :invalid) if fixed_cap_minor_snapshot.present?
      end
    end

    def asking_amount_within_cap
      return if asking_amount_minor.blank? || calculated_cap_minor.blank?
      return if asking_amount_minor <= calculated_cap_minor

      errors.add(:asking_amount_minor, :invalid)
    end

    def reservation_shape
      reserved = status.in?(%w[reserved sold])
      has_reservation = reserved_order_id.present? && reserved_at.present? && reservation_expires_at.present?
      return if reserved == has_reservation

      errors.add(:reserved_order_id, :invalid)
    end

    def lifecycle_shape
      if status.in?(%w[active reserved sold])
        errors.add(:activated_at, :blank) if activated_at.blank?
      elsif activated_at.present?
        errors.add(:activated_at, :invalid)
      end

      if status == "sold"
        errors.add(:sold_at, :blank) if sold_at.blank?
      elsif sold_at.present?
        errors.add(:sold_at, :invalid)
      end

      closed = status.in?(%w[sold cancelled expired])
      if closed
        errors.add(:closed_at, :blank) if closed_at.blank?
      elsif closed_at.present?
        errors.add(:closed_at, :invalid)
      end
    end

    def ticket_scope
      return if ticket_id.blank? || event_id.blank? || ticket_type_id.blank? || seller_user_id.blank?

      ticket_event_id, product_id, owner_user_id, acquisition_value, acquisition_currency =
        Ticketing::Ticket.where(id: ticket_id).pick(
          :event_id, :event_product_id, :owner_user_id,
          :current_acquisition_product_value_minor, :current_acquisition_currency
        )
      product_event_id, product_ticket_type_id = Catalog::EventProduct.joins(:ticket_type)
        .where(id: product_id)
        .pick("catalog_event_products.event_id", "ticketing_ticket_types.id")
      event_currency = Events::Event.where(id: event_id).pick(:currency)

      errors.add(:event, :invalid) unless ticket_event_id == event_id && product_event_id == event_id
      errors.add(:ticket_type, :invalid) unless product_ticket_type_id == ticket_type_id
      errors.add(:seller_user, :invalid) unless owner_user_id == seller_user_id
      errors.add(:seller_acquisition_product_value_minor, :invalid) unless acquisition_value == seller_acquisition_product_value_minor
      errors.add(:currency, :invalid) unless acquisition_currency == currency && event_currency == currency
    end
  end
end
