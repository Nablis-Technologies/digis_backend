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
    RESALE_MAX_PERCENTAGE_BPS = 10_000
    MAX_COMPLETED_RESALES = 32_767

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
    has_many :purchase_limit_allocations,
             class_name: "Ticketing::PurchaseLimitAllocation",
             dependent: :restrict_with_exception
    has_many :purchase_limit_overrides,
             class_name: "Ticketing::PurchaseLimitOverride",
             dependent: :restrict_with_exception

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
    validates :resale_fixed_cap_minor,
              numericality: {
                only_integer: true,
                greater_than: 0,
                message: I18n.t("ticketing.ticket_type.errors.resale_fixed_cap_minor_positive")
              },
              allow_nil: true
    validates :resale_fixed_cap_currency,
              format: { with: /\A[A-Z]{3}\z/ },
              allow_nil: true
    validates :resale_percentage_cap_bps,
              numericality: {
                only_integer: true,
                greater_than: 0,
                less_than_or_equal_to: RESALE_MAX_PERCENTAGE_BPS,
                message: I18n.t("ticketing.ticket_type.errors.resale_percentage_cap_range")
              },
              allow_nil: true
    validates :max_packages_per_user,
              numericality: { only_integer: true, greater_than_or_equal_to: 1 },
              allow_nil: true
    validate :resale_cap_consistency
    validate :resale_fixed_cap_currency_matches_event
    validate :max_completed_resales_within_platform_limit
    validate :admissions_per_unit_locked_if_committed, if: :admissions_per_unit_changed?

    before_validation :normalize_resale_fields

    scope :public_audience, -> { where(audience: "public") }
    scope :with_access_code, -> { where(audience: %w[access_code code_or_invitation]) }
    scope :with_invitation, -> { where(audience: %w[invitation code_or_invitation]) }
    scope :transferable, -> { where(transferable: true) }

    def admission_line(product:, selected_event_date_id:, package_quantity:, admissions_per_unit:)
      Catalog::Inventory::AdmissionLine.call(
        product:,
        selected_event_date_id:,
        package_quantity:,
        admissions_per_unit:
      )
    end

    def covered_date_ids(registration)
      admission_line_for(registration).event_date_ids
    end

    def covered_venue_date_ids(registration)
      admission_line_for(registration).venue_event_date_ids
    end

    def admission_line_for(registration)
      admission_line(
        product: event_product,
        selected_event_date_id: registration.selected_event_date_id,
        package_quantity: registration.package_quantity,
        admissions_per_unit: registration.admissions_per_unit_snapshot
      )
    end

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
      unless resale_enabled
        if resale_price_cap_type.present? || resale_fixed_cap_minor.present? ||
            resale_fixed_cap_currency.present? || resale_percentage_cap_bps.present?
          errors.add(:resale_price_cap_type, I18n.t("ticketing.ticket_type.errors.resale_cap_must_be_blank_when_disabled"))
        end
        return
      end

      if resale_price_cap_type.blank?
        errors.add(:resale_price_cap_type, I18n.t("ticketing.ticket_type.errors.resale_price_cap_type_required"))
        return
      end

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

    def max_completed_resales_within_platform_limit
      return if max_completed_resales.blank? || max_completed_resales <= MAX_COMPLETED_RESALES

      errors.add(:max_completed_resales, I18n.t("ticketing.ticket_type.errors.max_completed_resales_too_large"))
    end

    def resale_fixed_cap_currency_matches_event
      return unless resale_enabled && resale_price_cap_type == "fixed" && resale_fixed_cap_currency.present?

      event_currency = resale_event_currency
      return if event_currency.blank? || resale_fixed_cap_currency == event_currency

      errors.add(
        :resale_fixed_cap_currency,
        I18n.t("ticketing.ticket_type.errors.resale_fixed_cap_currency_mismatch")
      )
    end

    def resale_event_currency
      # Draft products may not have a foreign key yet; use already-built
      # associations first and query only the event currency when necessary.
      # This keeps validation strict-loading safe without weakening the
      # cross-table settlement-currency invariant.
      product = association(:event_product).target
      event = product&.association(:event)&.target
      return event.currency if event
      return if event_product_id.blank?

      Events::Event
        .joins(:event_products)
        .where(catalog_event_products: { id: event_product_id })
        .pick(:currency)
    end

    def normalize_resale_fields
      self.resale_price_cap_type = resale_price_cap_type.to_s.downcase.presence
      self.resale_fixed_cap_currency = resale_fixed_cap_currency.to_s.upcase.presence
    end

    def admissions_per_unit_locked_if_committed
      return unless committed?

      errors.add(:admissions_per_unit, I18n.t("ticketing.ticket_type.errors.admissions_per_unit_locked"))
    end

    # Package size is immutable once any registration, inventory reservation,
    # or order item references this ticket product. Orders store the product
    # identity rather than duplicating the ticket-type identity, so each
    # commitment source supplies its own lookup column and value. Tables may
    # not exist in every phase, so we probe defensively and treat a missing
    # source as "no commitment".
    def committed?
      return false unless persisted?

      commitment_sources = [
        [ "ticketing_registrations", "ticket_type_id", id ],
        [ "ticketing_inventory_reservations", "ticket_type_id", id ],
        [ "orders_order_items", "event_product_id", event_product_id ]
      ]

      commitment_sources.each do |table, column, value|
        next unless ActiveRecord::Base.connection.data_source_exists?(table)

        if ActiveRecord::Base.connection.select_value(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT 1 FROM #{table} WHERE #{column} = ? LIMIT 1", value ])
        )
          return true
        end
      end
      false
    end
  end
end
