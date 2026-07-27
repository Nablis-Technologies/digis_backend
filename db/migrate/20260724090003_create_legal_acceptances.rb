# frozen_string_literal: true

class CreateLegalAcceptances < ActiveRecord::Migration[8.1]
  def change
    create_table :legal_acceptances, id: :uuid, default: -> { "uuidv7()" } do |t|
      t.string :subject_type, null: false
      t.uuid :subject_id, null: false
      t.uuid :legal_document_version_id, null: false
      t.uuid :accepted_by_user_id, null: false
      t.string :acceptance_method, null: false, default: "checkbox"
      t.string :accepted_by_role
      t.string :content_sha256, null: false, limit: 64
      t.string :evidence_digest, null: false, limit: 64
      t.uuid :request_uuid, null: false
      t.datetime :accepted_at, null: false
      t.timestamps
    end

    add_check_constraint :legal_acceptances,
      "subject_type IN ('user','organization','order')",
      name: "chk_legal_acceptance_subject_type"
    add_check_constraint :legal_acceptances,
      "acceptance_method IN ('checkbox','otp')",
      name: "chk_legal_acceptance_method"
    add_index :legal_acceptances,
      %i[subject_type subject_id legal_document_version_id],
      unique: true, name: "idx_unique_legal_acceptance"
    add_index :legal_acceptances,
              %i[accepted_by_user_id accepted_at],
              name: "idx_legal_acceptances_by_actor"
    add_index :legal_acceptances, :request_uuid,
              unique: true,
              name: "idx_unique_legal_acceptance_request_uuid"
    add_foreign_key :legal_acceptances, :legal_document_versions,
                    column: :legal_document_version_id, on_delete: :restrict
    add_foreign_key :legal_acceptances, :core_users,
                    column: :accepted_by_user_id, on_delete: :restrict
  end
end
