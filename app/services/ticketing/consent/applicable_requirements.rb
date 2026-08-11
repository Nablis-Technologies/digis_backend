# frozen_string_literal: true

module Ticketing
  module Consent
    # Projects only the active current versions a buyer must review before
    # registration, applying the same event-wide/product-scoped rules as the
    # registration-time requirement snapshot.
    class ApplicableRequirements < Core::BaseService
      def initialize(event:, ticket_type:)
        @event = event
        @ticket_type = ticket_type
      end

      def call
        success(current_versions)
      end

      private

      attr_reader :event, :ticket_type

      def current_versions
        documents = Events::ConsentDocument
          .where(event_id: event.id, active: true)
          .includes(:consent_document_products)
          .to_a
        return [] if documents.empty?

        Events::ConsentDocumentVersion
          .where(consent_document_id: documents.map(&:id), status: "published")
          .includes(consent_document: %i[versions consent_document_products])
          .to_a
          .select { |version| current?(version) && applicable?(version) }
          .sort_by { |version| [ version.consent_document.name, version.version, version.id ] }
      end

      def current?(version)
        document = version.consent_document
        document.active? && document.versions.none? { |candidate| candidate.published? && candidate.id != version.id }
      end

      def applicable?(version)
        products = version.consent_document.consent_document_products
        products.empty? || products.any? { |product| product.ticket_type_id == ticket_type.id }
      end
    end
  end
end
