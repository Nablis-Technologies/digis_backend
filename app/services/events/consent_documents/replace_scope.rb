# frozen_string_literal: true

module Events
  module ConsentDocuments
    # Replaces the ticket-product scope of a consent document. Pass an empty
    # list to make the document apply to every ticket product in the event. The
    # document is advisory-locked so concurrent callers cannot interleave scope
    # replacements, and every new row is validated for same-event membership.
    class ReplaceScope < Core::BaseService
      def initialize(consent_document:, ticket_type_ids: [])
        @consent_document = consent_document
        @ticket_type_ids = ticket_type_ids
      end

      def call
        ActiveRecord::Base.transaction do
          Core::Database::AdvisoryLock.acquire!("consent_document_scope", @consent_document.id)

          @consent_document.consent_document_products.destroy_all

          @ticket_type_ids.each do |ticket_type_id|
            ticket_type = Ticketing::TicketType.find(ticket_type_id)
            row = Events::ConsentDocumentProduct.new(
              consent_document: @consent_document,
              ticket_type: ticket_type
            )
            unless row.valid?
              return failure(Core::Error.new(row.errors.full_messages.join(", ")))
            end

            row.save!
          end

          success(@consent_document.reload)
        end
      rescue Core::Error => e
        failure(e)
      end
    end
  end
end
