# frozen_string_literal: true

module Events
  # Optional ticket-product scope for a consent document. No rows means the
  # document applies to every ticket product in the event. The
  # (consent_document_id, ticket_type_id) pair is unique and both sides must
  # belong to the same event.
  class ConsentDocumentProduct < Events::ApplicationRecord
    self.table_name = "events_consent_document_products"

    belongs_to :consent_document,
               class_name: "Events::ConsentDocument",
               inverse_of: :consent_document_products
    belongs_to :ticket_type,
               class_name: "Ticketing::TicketType",
               inverse_of: :consent_document_products

    validates :consent_document, presence: true
    validates :ticket_type, presence: true
    validate :same_event

    def self.ransackable_attributes(_auth_object = nil)
      %w[id consent_document_id ticket_type_id created_at updated_at]
    end

    def self.ransackable_associations(_auth_object = nil)
      %w[consent_document ticket_type]
    end

    private

    def same_event
      return if consent_document.blank? || ticket_type.blank?

      doc_event = consent_document.event_id
      product_event = ticket_type.event_product&.event_id
      return if doc_event.blank? || product_event.blank?
      return if doc_event == product_event

      errors.add(:ticket_type, I18n.t("events.consent_document_product.errors.ticket_type_event_mismatch"))
    end
  end
end
