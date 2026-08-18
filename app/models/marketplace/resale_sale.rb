# frozen_string_literal: true

module Marketplace
  # Completed handoff of one reserved listing. This row is the immutable
  # commercial bridge between the resale order/payment and the ticket
  # ownership transition performed by the later Marketplace services.
  class ResaleSale < Marketplace::ApplicationRecord
    self.table_name = "marketplace_resale_sales"
    self.inheritance_column = nil

    STATUSES = %w[completed partially_cancelled cancelled].freeze
    FEE_CALCULATION_TYPES = %w[explicit_zero fixed percentage blended tiered].freeze
    FEE_BASIS_TYPES = %w[resale_acquisition_amount accepted_gross].freeze

    belongs_to :resale_listing, class_name: "Marketplace::ResaleListing"
    belongs_to :event, class_name: "Events::Event"
    belongs_to :ticket, class_name: "Ticketing::Ticket"
    belongs_to :seller_user, class_name: "Core::User"
    belongs_to :buyer_user, class_name: "Core::User"
    belongs_to :buyer_registration, class_name: "Ticketing::Registration"
    belongs_to :buyer_order, class_name: "Orders::Order"
    belongs_to :buyer_order_item, class_name: "Orders::OrderItem"
    belongs_to :accepted_payment, class_name: "Orders::Payment"
    belongs_to :seller_acquisition_order_item, class_name: "Orders::OrderItem"
    belongs_to :commercial_fee_component, class_name: "Commercial::FeeComponent"
    belongs_to :commercial_fee_schedule_version, class_name: "Commercial::FeeScheduleVersion"

    validate :immutable_snapshot
    before_destroy :prevent_mutation

    validates :resale_listing, :event, :ticket, :seller_user, :buyer_user, :buyer_registration,
              :buyer_order, :buyer_order_item, :accepted_payment, :seller_acquisition_order_item,
              :resale_number, :gross_amount_minor, :currency, :marketplace_fee_minor,
              :seller_proceeds_minor, :commercial_fee_component, :commercial_fee_schedule_version,
              :fee_calculation_type, :fee_basis_type, :status, :idempotency_key, presence: true
    validates :status, inclusion: { in: STATUSES }
    validates :fee_calculation_type, inclusion: { in: FEE_CALCULATION_TYPES }
    validates :fee_basis_type, inclusion: { in: FEE_BASIS_TYPES }
    validates :resale_number, numericality: { only_integer: true, greater_than: 0 }
    validates :gross_amount_minor,
              numericality: { only_integer: true, greater_than: 0 }
    validates :seller_proceeds_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :marketplace_fee_minor, :fee_fixed_amount_minor, :fee_rate_bps, presence: true
    validates :marketplace_fee_minor, :fee_fixed_amount_minor, :fee_minimum_minor, :fee_maximum_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validates :fee_rate_bps, numericality: { only_integer: true, in: 0..10_000 }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }
    validates :idempotency_key, uniqueness: true

    validate :seller_and_buyer_differ
    validate :gross_reconciles
    validate :payment_scope
    validate :status_metadata

    def completed?
      status == "completed"
    end

    def self.ransackable_attributes(_auth_object = nil)
      %w[id resale_listing_id event_id ticket_id seller_user_id buyer_user_id buyer_registration_id buyer_order_id
         buyer_order_item_id accepted_payment_id seller_acquisition_order_item_id resale_number gross_amount_minor
         currency marketplace_fee_minor seller_proceeds_minor commercial_fee_component_id
         commercial_fee_schedule_version_id fee_calculation_type fee_basis_type fee_fixed_amount_minor fee_rate_bps
         fee_minimum_minor fee_maximum_minor status completed_at idempotency_key created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[resale_listing event ticket seller_user buyer_user buyer_registration buyer_order buyer_order_item
         accepted_payment seller_acquisition_order_item commercial_fee_component commercial_fee_schedule_version]
    end

    private

    def seller_and_buyer_differ
      return if seller_user_id.blank? || buyer_user_id.blank? || seller_user_id != buyer_user_id

      errors.add(:buyer_user, :invalid)
    end

    def gross_reconciles
      return if [ gross_amount_minor, marketplace_fee_minor, seller_proceeds_minor ].any?(&:nil?)
      return if gross_amount_minor == marketplace_fee_minor + seller_proceeds_minor

      errors.add(:gross_amount_minor, :invalid)
    end

    def payment_scope
      return if accepted_payment_id.blank? || buyer_order_id.blank?

      payment_order_id, payment_status, accepted_at, payment_amount, payment_currency = Orders::Payment.where(
        id: accepted_payment_id
      ).pick(:order_id, :status, :accepted_at, :amount_minor, :currency)
      order_amount, order_currency, order_settlement_amount, order_settlement_currency, order_event_id, order_buyer_id =
        Orders::Order.where(id: buyer_order_id)
          .pick(:total_minor, :charge_currency, :settlement_total_minor, :settlement_currency, :event_id, :buyer_user_id)

      errors.add(:accepted_payment, :invalid) unless payment_order_id == buyer_order_id &&
        payment_status == "succeeded" && accepted_at.present? && payment_amount == order_amount &&
        payment_currency == order_currency
      errors.add(:buyer_order, :invalid) unless order_settlement_amount == gross_amount_minor &&
        order_settlement_currency == currency && order_event_id == event_id && order_buyer_id == buyer_user_id
    end

    def status_metadata
      errors.add(:completed_at, :blank) if completed_at.blank?
    end

    def immutable_snapshot
      return unless persisted?

      immutable_fields = %i[
        resale_listing_id event_id ticket_id seller_user_id buyer_user_id buyer_registration_id
        buyer_order_id buyer_order_item_id accepted_payment_id seller_acquisition_order_item_id
        resale_number gross_amount_minor currency marketplace_fee_minor seller_proceeds_minor
        commercial_fee_component_id commercial_fee_schedule_version_id fee_calculation_type
        fee_basis_type fee_fixed_amount_minor fee_rate_bps fee_minimum_minor fee_maximum_minor
      ]

      immutable_fields.each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end

    def prevent_mutation
      raise ActiveRecord::ReadOnlyRecord, I18n.t("errors.messages.immutable")
    end
  end
end
