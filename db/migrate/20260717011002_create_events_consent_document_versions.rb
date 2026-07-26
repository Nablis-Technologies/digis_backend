# frozen_string_literal: true

class CreateEventsConsentDocumentVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :events_consent_document_versions, id: :uuid do |t|
      t.uuid :consent_document_id, null: false
      t.integer :version,          null: false
      t.string :title,             null: false
      t.text :body,                null: false
      t.string :content_sha256,    null: false, limit: 64
      t.boolean :required,         null: false, default: true
      t.string :acceptance_scope,  default: "buyer"
      t.string :status,            null: false, default: "draft"
      t.uuid :published_by_id
      t.timestamp :published_at
      t.uuid :created_by_id,       null: false
      t.timestamps
    end

    add_index :events_consent_document_versions, %i[consent_document_id version],
              unique: true,
              name: "index_consent_versions_on_doc_version"
    add_index :events_consent_document_versions, :consent_document_id,
              unique: true,
              where: "status = 'published'",
              name: "index_one_published_version_per_doc"
    add_check_constraint :events_consent_document_versions,
                         "status IN ('draft','published','retired')",
                         name: "chk_consent_version_status"
    add_foreign_key :events_consent_document_versions, :events_consent_documents,
                    column: :consent_document_id, on_delete: :cascade
    add_foreign_key :events_consent_document_versions, :core_users,
                    column: :created_by_id, on_delete: :restrict
    add_foreign_key :events_consent_document_versions, :core_users,
                    column: :published_by_id, on_delete: :restrict
  end
end
