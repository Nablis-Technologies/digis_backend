# frozen_string_literal: true

module Commercial
  # Holds one immutable order-linked platform subsidy amount against a hard
  # currency budget. Counters live on SubsidyBudget; commands lock the budget
  # before this row so concurrent checkout cannot overspend the cap.
  class SubsidyReservation < Commercial::ApplicationRecord
    self.table_name = "commercial_subsidy_reservations"

    STATUSES = %w[held processing committed released].freeze
    ACTIVE_STATUSES = %w[held processing].freeze
    TERMINAL_STATUSES = %w[committed released].freeze
    SNAPSHOT_ATTRIBUTES = %w[
      subsidy_budget_id order_id idempotency_key_digest request_fingerprint amount_minor currency
    ].freeze

    belongs_to :subsidy_budget,
               class_name: "Commercial::SubsidyBudget",
               inverse_of: :subsidy_reservations
    belongs_to :order,
               class_name: "Orders::Order",
               inverse_of: :subsidy_reservations

    before_validation :normalize_currency
    before_destroy :prevent_destroy

    validates :subsidy_budget_id, :order_id, presence: true
    validates :idempotency_key_digest, :request_fingerprint,
              presence: true,
              format: { with: /\A[0-9a-f]{64}\z/ }
    validates :amount_minor, numericality: { only_integer: true, greater_than: 0 }
    validates :currency,
              presence: true,
              format: { with: /\A[A-Z]{3}\z/ }
    validates :status, presence: true, inclusion: { in: STATUSES }

    validate :currency_matches_budget_and_order
    validate :state_metadata
    validate :snapshot_immutable
    validate :terminal_immutable

    scope :active, -> { where(status: ACTIVE_STATUSES) }
    scope :held, -> { where(status: "held") }
    scope :processing, -> { where(status: "processing") }
    scope :terminal, -> { where(status: TERMINAL_STATUSES) }
    scope :expired, ->(at = Time.current) { active.where("expires_at <= ?", at) }

    def held? = status == "held"

    def processing? = status == "processing"

    def committed? = status == "committed"

    def released? = status == "released"

    def active? = ACTIVE_STATUSES.include?(status)

    def terminal? = TERMINAL_STATUSES.include?(status)

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id subsidy_budget_id order_id idempotency_key_digest request_fingerprint amount_minor currency
        status expires_at committed_at released_at created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[subsidy_budget order]
    end

    private

    def normalize_currency
      self.currency = currency.to_s.strip.upcase.presence
    end

    def currency_matches_budget_and_order
      return if currency.blank?

      budget_currency = if association(:subsidy_budget).loaded?
        subsidy_budget&.currency
      elsif subsidy_budget_id.present?
        Commercial::SubsidyBudget.where(id: subsidy_budget_id).pick(:currency)
      end
      order_currency = if association(:order).loaded?
        order&.charge_currency
      elsif order_id.present?
        Orders::Order.where(id: order_id).pick(:charge_currency)
      end
      return if budget_currency.blank? || order_currency.blank?
      return if budget_currency == currency && order_currency == currency

      errors.add(:currency, I18n.t("commercial.subsidies.errors.reservation_currency_mismatch"))
    end

    def state_metadata
      if active?
        errors.add(:expires_at, I18n.t("commercial.subsidies.errors.reservation_expiry_required")) if expires_at.blank?
        errors.add(:committed_at, I18n.t("commercial.subsidies.errors.reservation_timestamp_invalid")) if committed_at.present?
        errors.add(:released_at, I18n.t("commercial.subsidies.errors.reservation_timestamp_invalid")) if released_at.present?
      elsif committed?
        errors.add(:committed_at, I18n.t("commercial.subsidies.errors.reservation_timestamp_required")) if committed_at.blank?
        errors.add(:released_at, I18n.t("commercial.subsidies.errors.reservation_timestamp_invalid")) if released_at.present?
      elsif released?
        errors.add(:released_at, I18n.t("commercial.subsidies.errors.reservation_timestamp_required")) if released_at.blank?
        errors.add(:committed_at, I18n.t("commercial.subsidies.errors.reservation_timestamp_invalid")) if committed_at.present?
      end
    end

    def snapshot_immutable
      return unless persisted?

      SNAPSHOT_ATTRIBUTES.each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end

    def terminal_immutable
      return unless persisted? && TERMINAL_STATUSES.include?(status_in_database)

      %w[status committed_at released_at].each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end

    def prevent_destroy
      raise ActiveRecord::ReadOnlyRecord, I18n.t("commercial.subsidies.errors.reservation_immutable")
    end
  end
end
