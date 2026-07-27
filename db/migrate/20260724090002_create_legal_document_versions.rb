# frozen_string_literal: true

class CreateLegalDocumentVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :legal_document_versions, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.uuid :legal_document_id, null: false
      t.integer :version, null: false
      t.string :title, null: false
      t.text :body, null: false
      t.string :content_sha256, null: false, limit: 64
      t.string :status, null: false, default: "draft"
      t.string :commercial_policy_reference
      t.uuid :published_by_id
      t.timestamp :published_at
      t.uuid :created_by_id, null: false
      t.timestamps
    end

    add_index :legal_document_versions, %i[legal_document_id version],
              unique: true, name: "index_legal_versions_on_doc_version"
    add_index :legal_document_versions, :legal_document_id, unique: true,
              where: "status = 'published'",
              name: "index_one_published_legal_doc"
    add_check_constraint :legal_document_versions,
      "status IN ('draft','published','retired')",
      name: "chk_legal_version_status"
    add_foreign_key :legal_document_versions, :legal_documents,
                    column: :legal_document_id, on_delete: :restrict
    add_foreign_key :legal_document_versions, :core_users,
                    column: :created_by_id, on_delete: :restrict
    add_foreign_key :legal_document_versions, :core_users,
                    column: :published_by_id, on_delete: :restrict
  end
end
