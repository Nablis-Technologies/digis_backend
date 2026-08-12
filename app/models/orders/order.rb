# frozen_string_literal: true

module Orders
  # Event-scoped financial aggregate. Draft pricing may be assembled by the
  # checkout command; once payment begins, the financial and FX snapshots stay
  # fixed while lifecycle status and payment evidence continue to evolve.
  class Order < Orders::ApplicationRecord
    self.table_name = "orders_orders"

    STATUSES = %w[
      draft pending_payment paid fulfilled expired cancelled partially_refunded refunded
    ].freeze
    SALES_CHANNELS = %w[online walk_up resale].freeze
    CLOSED_STATUSES = %w[expired cancelled].freeze
    PAID_STATUSES = %w[paid fulfilled partially_refunded refunded].freeze
    IMMUTABLE_STATUSES = (STATUSES - [ "draft" ]).freeze
    SNAPSHOT_ATTRIBUTES = %w[
      event_id buyer_user_id sales_channel initiated_by_id replaces_order_id
      charge_currency commercial_signature subtotal_minor discount_minor subsidy_minor fee_minor tax_minor
      adjustment_minor total_minor settlement_currency settlement_total_minor exchange_rate
      exchange_rate_source exchange_rate_quoted_at exchange_rate_expires_at expires_at
      idempotency_key_digest creation_request_digest
    ].freeze

    belongs_to :event, class_name: "Events::Event"
    belongs_to :buyer_user, class_name: "Core::User"
    belongs_to :initiated_by,
               class_name: "Core::User",
               optional: true
    belongs_to :replaces_order,
               class_name: "Orders::Order",
               optional: true,
               inverse_of: :replacement_order

    has_one :replacement_order,
            class_name: "Orders::Order",
            foreign_key: :replaces_order_id,
            inverse_of: :replaces_order
    has_many :order_items,
             class_name: "Orders::OrderItem",
             inverse_of: :order,
             dependent: :restrict_with_exception
    has_many :order_adjustments,
             class_name: "Orders::OrderAdjustment",
             inverse_of: :order,
             dependent: :restrict_with_exception
    has_many :subsidy_reservations,
             class_name: "Commercial::SubsidyReservation",
             inverse_of: :order,
             dependent: :restrict_with_exception
    has_many :volume_usages,
             class_name: "Commercial::VolumeUsage",
             inverse_of: :order,
             dependent: :restrict_with_exception
    has_many :payments,
             class_name: "Orders::Payment",
             inverse_of: :order,
             dependent: :restrict_with_exception
    has_one :promotion_redemption,
            class_name: "Orders::PromotionRedemption",
            inverse_of: :order,
            dependent: :restrict_with_exception

    before_validation :normalize_currencies
    before_destroy :prevent_destroy_if_immutable

    validates :event, :buyer_user, presence: true
    validates :sales_channel, presence: true, inclusion: { in: SALES_CHANNELS }
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :charge_currency, :settlement_currency,
              presence: true,
              format: { with: /\A[A-Z]{3}\z/ }
    validates :commercial_signature,
              presence: true,
              format: { with: /\A[0-9a-f]{64}\z/ }
    validates :expires_at, presence: true
    validates :exchange_rate,
              presence: true,
              numericality: { greater_than: 0 }
    validates :exchange_rate_source, presence: true
    validates :idempotency_key_digest, :creation_request_digest,
              presence: true,
              format: { with: /\A[0-9a-f]{64}\z/ }
    validates :subtotal_minor, :discount_minor, :subsidy_minor, :fee_minor,
              :tax_minor, :total_minor, :settlement_total_minor,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :adjustment_minor,
              numericality: { only_integer: true }

    validate :total_reconciles
    validate :state_metadata
    validate :exchange_rate_metadata
    validate :replacement_scope
    validate :snapshot_immutable

    scope :active_checkouts, -> { where(status: %w[draft pending_payment]) }
    scope :closed, -> { where(status: CLOSED_STATUSES) }

    def draft? = status == "draft"

    def pending_payment? = status == "pending_payment"

    def paid? = PAID_STATUSES.include?(status)

    def closed? = CLOSED_STATUSES.include?(status)

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_id buyer_user_id initiated_by_id replaces_order_id sales_channel status
        closed_reason charge_currency subtotal_minor discount_minor subsidy_minor fee_minor
        tax_minor adjustment_minor total_minor settlement_currency settlement_total_minor
        exchange_rate exchange_rate_source exchange_rate_quoted_at exchange_rate_expires_at
        expires_at paid_at created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event buyer_user initiated_by replaces_order replacement_order order_items order_adjustments
         promotion_redemption subsidy_reservations volume_usages payments]
    end

    private

    def normalize_currencies
      self.charge_currency = charge_currency.to_s.strip.upcase.presence
      self.settlement_currency = settlement_currency.to_s.strip.upcase.presence
    end

    def total_reconciles
      return if [ subtotal_minor, discount_minor, subsidy_minor, fee_minor, tax_minor,
                  adjustment_minor, total_minor ].any?(&:nil?)
      return if total_minor == subtotal_minor - discount_minor - subsidy_minor + fee_minor + tax_minor + adjustment_minor

      errors.add(:total_minor, :invalid)
    end

    def state_metadata
      if closed?
        errors.add(:closed_reason, :blank) if closed_reason.blank?
      elsif closed_reason.present?
        errors.add(:closed_reason, :invalid)
      end

      if paid?
        errors.add(:paid_at, :blank) if paid_at.blank?
      elsif paid_at.present?
        errors.add(:paid_at, :invalid)
      end
    end

    def exchange_rate_metadata
      return if charge_currency.blank? || settlement_currency.blank?

      if charge_currency == settlement_currency
        errors.add(:exchange_rate, :invalid) unless exchange_rate == 1
        return
      end

      errors.add(:exchange_rate_quoted_at, :blank) if exchange_rate_quoted_at.blank?
      errors.add(:exchange_rate_expires_at, :blank) if exchange_rate_expires_at.blank?
      return if exchange_rate_quoted_at.blank? || exchange_rate_expires_at.blank?

      return if exchange_rate_expires_at > exchange_rate_quoted_at

      errors.add(:exchange_rate_expires_at, :invalid)
    end

    def replacement_scope
      return if replaces_order.blank?
      return if replaces_order.event_id == event_id &&
        replaces_order.buyer_user_id == buyer_user_id &&
        CLOSED_STATUSES.include?(replaces_order.status)

      errors.add(:replaces_order, :invalid)
    end

    def snapshot_immutable
      return unless persisted?

      immutable_status = IMMUTABLE_STATUSES.include?(status_in_database) ||
        IMMUTABLE_STATUSES.include?(status)
      return unless immutable_status

      SNAPSHOT_ATTRIBUTES.each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end

    def prevent_destroy_if_immutable
      return unless IMMUTABLE_STATUSES.include?(status_in_database)

      raise ActiveRecord::ReadOnlyRecord, I18n.t("errors.messages.immutable")
    end
  end
end
