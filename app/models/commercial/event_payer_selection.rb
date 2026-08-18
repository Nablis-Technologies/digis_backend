# frozen_string_literal: true

module Commercial
  # Stores the current event-level payer choice. Audit rows retain every
  # change; this projection is intentionally mutable so a new permitted choice
  # can replace an earlier one without rewriting commercial terms.
  class EventPayerSelection < Commercial::ApplicationRecord
    self.table_name = "commercial_event_payer_selections"

    PAYERS = %w[buyer organizer].freeze

    belongs_to :event,
               class_name: "Events::Event"
    belongs_to :fee_component,
               class_name: "Commercial::FeeComponent",
               inverse_of: :event_payer_selections
    belongs_to :selected_by,
               class_name: "Core::User",
               optional: true

    before_validation :normalize_payer

    validates :event, :fee_component, :charged_to, :selected_at,
              :idempotency_key_digest, :request_fingerprint, presence: true
    validates :charged_to, inclusion: { in: PAYERS }
    validates :idempotency_key_digest, :request_fingerprint,
              format: { with: /\A[0-9a-f]{64}\z/ }
    validates :event_id, uniqueness: { scope: :fee_component_id }

    validate :event_product_scope
    validate :payer_is_permitted

    def self.ransackable_attributes(_auth_object = nil)
      %w[
        id event_id fee_component_id charged_to selected_by_id selected_at
        idempotency_key_digest request_fingerprint created_at updated_at
      ]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[event fee_component selected_by]
    end

    private

    def normalize_payer
      self.charged_to = charged_to.to_s.strip.downcase.presence
    end

    def event_product_scope
      return if event.blank? || fee_component.blank? || fee_component.event_product_id.blank?
      product_event_id = Catalog::EventProduct.where(id: fee_component.event_product_id).pick(:event_id)
      return if product_event_id == event_id

      errors.add(:event, I18n.t("commercial.volume.errors.selection_event_mismatch"))
    end

    def payer_is_permitted
      return if fee_component.blank? || charged_to.blank?
      return if charged_to == fee_component.charged_to || fee_component.organizer_payer_choice

      errors.add(:charged_to, I18n.t("commercial.volume.errors.payer_selection_forbidden"))
    end
  end
end
