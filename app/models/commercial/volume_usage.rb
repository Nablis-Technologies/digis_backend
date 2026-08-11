# frozen_string_literal: true

module Commercial
  # Immutable accepted-order activity used to rebuild VolumeCounter caches.
  # No correction edits or deletions are allowed; a future net-volume metric
  # must be introduced separately instead of changing accepted history.
  class VolumeUsage < Commercial::ApplicationRecord
    self.table_name = "commercial_volume_usages"

    METRIC_TYPES = Commercial::FeeTier::METRIC_TYPES
    WINDOW_TYPES = Commercial::FeeTier::WINDOW_TYPES
    SNAPSHOT_ATTRIBUTES = %w[
      fee_component_id organization_id event_id order_id metric_type window_type
      window_start_at window_end_at currency value accepted_at
    ].freeze

    belongs_to :fee_component,
               class_name: "Commercial::FeeComponent",
               inverse_of: :volume_usages
    belongs_to :organization,
               class_name: "Organizations::Organization"
    belongs_to :event,
               class_name: "Events::Event",
               optional: true
    belongs_to :order,
               class_name: "Orders::Order",
               inverse_of: :volume_usages

    before_validation :normalize_currency
    before_destroy :prevent_destroy

    validates :fee_component, :organization, :order, :metric_type, :window_type,
              :window_start_at, :accepted_at, presence: true
    validates :metric_type, inclusion: { in: METRIC_TYPES }
    validates :window_type, inclusion: { in: WINDOW_TYPES }
    validates :value, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }, allow_nil: true
    validates :order_id,
              uniqueness: {
                scope: %i[fee_component_id metric_type window_type currency
                          window_start_at window_end_at]
              }

    validate :currency_matches_metric
    validate :currency_matches_order
    validate :accepted_order
    validate :scope_matches_order
    validate :window_bounds
    validate :snapshot_immutable
    validate :event_required_for_event_window
    validate :component_scope

    scope :for_dimension, lambda { |attributes|
      where(
        fee_component_id: attributes[:fee_component_id],
        organization_id: attributes[:organization_id],
        event_id: attributes[:event_id],
        metric_type: attributes[:metric_type],
        window_type: attributes[:window_type],
        currency: attributes[:currency],
        window_start_at: attributes[:window_start_at],
        window_end_at: attributes[:window_end_at]
      )
    }

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id fee_component_id organization_id event_id order_id metric_type window_type
        window_start_at window_end_at currency value accepted_at created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[fee_component organization event order]
    end

    private

    def normalize_currency
      self.currency = currency.to_s.strip.upcase.presence
    end

    def currency_matches_metric
      if metric_type == "accepted_gross" && currency.blank?
        errors.add(:currency, I18n.t("commercial.volume.errors.currency_required"))
      elsif metric_type == "accepted_paid_units" && currency.present?
        errors.add(:currency, I18n.t("commercial.volume.errors.currency_forbidden"))
      end
    end

    def currency_matches_order
      return unless metric_type == "accepted_gross" && currency.present? && order.present?
      return if order.settlement_currency == currency

      errors.add(:currency, I18n.t("commercial.volume.errors.order_currency_mismatch"))
    end

    def accepted_order
      return if order.blank? || Orders::Order::PAID_STATUSES.include?(order.status)

      errors.add(:order, I18n.t("commercial.volume.errors.order_not_accepted"))
    end

    def scope_matches_order
      return if order.blank?

      order_organization_id = Events::Event.where(id: order.event_id).pick(:organization_id)
      if organization.present? && order_organization_id != organization_id
        errors.add(:organization, I18n.t("commercial.volume.errors.order_organization_mismatch"))
      end

      return if event_id.blank? || event_id == order.event_id

      errors.add(:event, I18n.t("commercial.volume.errors.order_event_mismatch"))
    end

    def window_bounds
      return if window_end_at.blank? || window_start_at.blank?
      return if window_end_at > window_start_at

      errors.add(:window_end_at, I18n.t("commercial.volume.errors.window_bounds"))
    end

    def event_required_for_event_window
      return unless window_type == "event" && event_id.blank?

      errors.add(:event, I18n.t("commercial.volume.errors.event_window_event_required"))
    end

    def component_scope
      return if fee_component.blank? || fee_component.event_product_id.blank? || order.blank?

      product_event_id = Catalog::EventProduct.where(id: fee_component.event_product_id).pick(:event_id)
      return if product_event_id == order.event_id

      errors.add(:fee_component, I18n.t("commercial.volume.errors.selection_event_mismatch"))
    end

    def snapshot_immutable
      return unless persisted?

      SNAPSHOT_ATTRIBUTES.each do |attribute|
        errors.add(attribute, :immutable) if will_save_change_to_attribute?(attribute)
      end
    end

    def prevent_destroy
      raise ActiveRecord::ReadOnlyRecord, I18n.t("commercial.volume.errors.usage_immutable")
    end
  end
end
