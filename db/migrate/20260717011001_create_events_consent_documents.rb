# frozen_string_literal: true

class CreateEventsConsentDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :events_consent_documents, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :event_id,      null: false
      t.string :type,        null: false
      t.string :name,        null: false
      t.boolean :active,     null: false, default: true
      t.uuid :created_by_id, null: false
      t.timestamps
    end

    add_index :events_consent_documents, %i[event_id name],
              unique: true,
              name: "index_consent_docs_on_event_name"
    add_check_constraint :events_consent_documents,
                         "type IN ('terms','liability_waiver','media_consent','age_declaration','other')",
                         name: "chk_consent_doc_type"
    add_foreign_key :events_consent_documents, :events_events,
                    column: :event_id, on_delete: :cascade
    add_foreign_key :events_consent_documents, :core_users,
                    column: :created_by_id, on_delete: :restrict
  end
end
