# frozen_string_literal: true

class CreateLegalDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :legal_documents, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :document_type, null: false
      t.string :internal_name, null: false
      t.string :jurisdiction_code, null: false, default: "GLOBAL"
      t.string :locale, null: false, default: "en"
      t.boolean :active, null: false, default: true
      t.uuid :created_by_id, null: false
      t.timestamps
    end

    add_index :legal_documents, %i[document_type jurisdiction_code locale],
              unique: true, name: "index_legal_docs_on_type_juris_locale"
    add_check_constraint :legal_documents,
      "document_type IN ('platform_terms','privacy_policy','organizer_agreement','organizer_fee_schedule','buyer_purchase_terms')",
      name: "chk_legal_doc_type"
    add_foreign_key :legal_documents, :core_users,
                    column: :created_by_id, on_delete: :restrict
  end
end
