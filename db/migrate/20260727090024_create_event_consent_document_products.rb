# frozen_string_literal: true

class CreateEventConsentDocumentProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :events_consent_document_products, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :consent_document_id, null: false
      t.uuid :ticket_type_id, null: false

      t.timestamps
    end

    add_index :events_consent_document_products,
              %i[consent_document_id ticket_type_id],
              unique: true
    add_foreign_key :events_consent_document_products,
                    :events_consent_documents,
                    column: :consent_document_id
    add_foreign_key :events_consent_document_products,
                    :ticketing_ticket_types,
                    column: :ticket_type_id
  end
end
