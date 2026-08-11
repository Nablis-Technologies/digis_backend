# frozen_string_literal: true

module Commercial
  # A locked cache of accepted commercial activity for one exact tier window.
  # VolumeUsage is the retained source of truth; this row exists only to make
  # prospective quote reads cheap and serializable at a threshold boundary.
  class VolumeCounter < Commercial::ApplicationRecord
    self.table_name = "commercial_volume_counters"

    METRIC_TYPES = Commercial::FeeTier::METRIC_TYPES
    WINDOW_TYPES = Commercial::FeeTier::WINDOW_TYPES

    belongs_to :fee_component,
               class_name: "Commercial::FeeComponent",
               inverse_of: :volume_counters
    belongs_to :organization,
               class_name: "Organizations::Organization"
    belongs_to :event,
               class_name: "Events::Event",
               optional: true

    before_validation :normalize_currency

    validates :fee_component, :organization, :metric_type, :window_type,
              :window_start_at, presence: true
    validates :metric_type, inclusion: { in: METRIC_TYPES }
    validates :window_type, inclusion: { in: WINDOW_TYPES }
    validates :value, :lock_version,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validates :currency, format: { with: /\A[A-Z]{3}\z/ }, allow_nil: true
    validates :fee_component_id,
              uniqueness: {
                scope: %i[organization_id event_id metric_type window_type currency
                          window_start_at window_end_at]
              }

    validate :currency_matches_metric
    validate :window_bounds
    validate :event_scope
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
        id fee_component_id organization_id event_id metric_type window_type
        window_start_at window_end_at currency value lock_version created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[fee_component organization event]
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

    def window_bounds
      return if window_end_at.blank? || window_start_at.blank?
      return if window_end_at > window_start_at

      errors.add(:window_end_at, I18n.t("commercial.volume.errors.window_bounds"))
    end

    def event_scope
      return if event.blank? || organization.blank?
      return if event.organization_id == organization_id

      errors.add(:event, I18n.t("commercial.volume.errors.event_organization_mismatch"))
    end

    def event_required_for_event_window
      return unless window_type == "event" && event_id.blank?

      errors.add(:event, I18n.t("commercial.volume.errors.event_window_event_required"))
    end

    def component_scope
      return if fee_component.blank? || fee_component.event_product_id.blank?

      product_event_id = Catalog::EventProduct.where(id: fee_component.event_product_id).pick(:event_id)
      return if product_event_id == event_id

      errors.add(:event, I18n.t("commercial.volume.errors.selection_event_mismatch"))
    end
  end
end
