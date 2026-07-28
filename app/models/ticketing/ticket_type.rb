# frozen_string_literal: true

module Ticketing
  # Ticket-only behavior attached one-to-one to a product whose type is
  # `ticket`. Encodes audience, approval, date selection, transfer/delegation,
  # entry validation, and resale policy.
  class TicketType < Ticketing::ApplicationRecord
    self.table_name = "ticketing_ticket_types"

    APPROVAL_MODES = %w[automatic manual].freeze
    AUDIENCES = %w[public access_code invitation code_or_invitation].freeze
    DATE_SELECTIONS = %w[fixed choose_one].freeze
    DELEGATION_MODES = %w[offline_allowed online_required].freeze
    ENTRY_MODES = %w[qr qr_and_id].freeze
    RESALE_CAP_TYPES = %w[fixed percentage].freeze

    belongs_to :event_product,
               class_name: "Catalog::EventProduct",
               inverse_of: :ticket_type
    has_one :event, through: :event_product

    has_many :access_codes,
             class_name: "Ticketing::AccessCode",
             inverse_of: :ticket_type,
             dependent: :destroy
    has_many :invitations,
             class_name: "Ticketing::Invitation",
             inverse_of: :ticket_type,
             dependent: :destroy
    has_many :consent_document_products,
             class_name: "Events::ConsentDocumentProduct",
             inverse_of: :ticket_type,
             dependent: :destroy

    validates :approval_mode, presence: true, inclusion: { in: APPROVAL_MODES }
    validates :audience, presence: true, inclusion: { in: AUDIENCES }
    validates :date_selection, presence: true, inclusion: { in: DATE_SELECTIONS }
    validates :delegation_validation_mode,
              presence: true,
              inclusion: { in: DELEGATION_MODES }
    validates :entry_validation_mode, presence: true, inclusion: { in: ENTRY_MODES }
    validates :transfer_cutoff_seconds_before_start,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :admissions_per_unit,
              numericality: { only_integer: true, greater_than_or_equal_to: 1 }
    validates :resale_cutoff_seconds_before_start,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :max_completed_resales,
              numericality: { only_integer: true, greater_than_or_equal_to: 1 }
    validates :max_packages_per_user,
              numericality: { only_integer: true, greater_than_or_equal_to: 1 },
              allow_nil: true
    validate :resale_cap_consistency
    validate :admissions_per_unit_locked_if_committed, if: :admissions_per_unit_changed?

    scope :public_audience, -> { where(audience: "public") }
    scope :with_access_code, -> { where(audience: %w[access_code code_or_invitation]) }
    scope :with_invitation, -> { where(audience: %w[invitation code_or_invitation]) }
    scope :transferable, -> { where(transferable: true) }

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_product_id approval_mode audience date_selection waitlist_enabled
        transferable transfer_cutoff_seconds_before_start admissions_per_unit
        delegation_enabled delegation_validation_mode entry_validation_mode
        max_packages_per_user resale_enabled resale_cutoff_seconds_before_start
        resale_price_cap_type resale_fixed_cap_minor resale_fixed_cap_currency
        resale_percentage_cap_bps max_completed_resales created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event_product event access_codes invitations consent_document_products]
    end

    private

    def resale_cap_consistency
      return if resale_price_cap_type.blank?

      if resale_price_cap_type == "fixed"
        errors.add(:resale_fixed_cap_minor, I18n.t("ticketing.ticket_type.errors.resale_fixed_cap_minor_required")) if resale_fixed_cap_minor.blank?
        errors.add(:resale_fixed_cap_currency, I18n.t("ticketing.ticket_type.errors.resale_fixed_cap_currency_required")) if resale_fixed_cap_currency.blank?
        errors.add(:resale_percentage_cap_bps, I18n.t("ticketing.ticket_type.errors.resale_percentage_cap_must_blank")) if resale_percentage_cap_bps.present?
      elsif resale_price_cap_type == "percentage"
        errors.add(:resale_percentage_cap_bps, I18n.t("ticketing.ticket_type.errors.resale_percentage_cap_required")) if resale_percentage_cap_bps.blank?
        errors.add(:resale_fixed_cap_minor, I18n.t("ticketing.ticket_type.errors.resale_fixed_cap_minor_must_blank")) if resale_fixed_cap_minor.present?
        errors.add(:resale_fixed_cap_currency, I18n.t("ticketing.ticket_type.errors.resale_fixed_cap_currency_must_blank")) if resale_fixed_cap_currency.present?
      else
        errors.add(:resale_price_cap_type, I18n.t("ticketing.ticket_type.errors.resale_price_cap_type_invalid"))
      end
    end

    def admissions_per_unit_locked_if_committed
      return unless committed?

      errors.add(:admissions_per_unit, I18n.t("ticketing.ticket_type.errors.admissions_per_unit_locked"))
    end

    # Package size is immutable once any registration, inventory reservation,
    # or order item references this ticket type. Tables may not exist in every
    # phase, so we probe defensively and treat a missing source as "no
    # commitment".
    def committed?
      return false unless persisted?

      %w[ticketing_registrations ticketing_inventory_reservations orders_order_items].each do |table|
        next unless ActiveRecord::Base.connection.data_source_exists?(table)

        if ActiveRecord::Base.connection.select_value(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT 1 FROM #{table} WHERE ticket_type_id = ? LIMIT 1", id ])
        )
          return true
        end
      end
      false
    end
  end
end
